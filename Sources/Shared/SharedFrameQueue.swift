//
//  SharedFrameQueue.swift
//  Columba Shared
//
//  Lock-free append-only queue backed by a shared file in the App Group container.
//  The Network Extension appends frames; the main app reads and clears them.
//
//  Frame format: [4-byte length (big-endian)][1-byte interface tag][N-byte frame data]
//  Interface tags: 0x01 = TCP, 0x02 = Auto
//

import Foundation

/// App Group identifier shared between the main app and the Network Extension.
/// Defined here because `Sources/Shared` is compiled into both targets.
public let appGroupIdentifier = "group.network.columba.Columba"

/// Identifiers shared between the Columba app target and the
/// `ColumbaNetworkExtension` so both refer to the same notification
/// names / UserDefaults keys without duplicating string literals.
public enum SharedDefaultsConstants {
    /// Darwin notification posted when the app writes to the
    /// interface-config UserDefaults. The extension observes this and
    /// reloads its sockets so user-facing changes (added relay,
    /// disabled interface, etc.) take effect without a tunnel
    /// restart.
    public static let configChangedNotificationName = "network.columba.configChanged"

    /// Darwin notification posted by the extension when inbound
    /// frames have been written to `SharedFrameQueue`. The app's
    /// `ExtensionFrameReader` observes this to drain the queue.
    public static let packetReadyNotificationName = "network.columba.packetReady"

    /// Shared UserDefaults key holding the JSON-encoded interface
    /// configuration array (full `InterfaceEntity` objects). Both the
    /// app's `InterfaceRepository` and the extension's
    /// `loadInterfaceConfigs` read from this key.
    public static let interfacesKey = "com.columba.interfaces"

    /// Shared UserDefaults key for the user's "Background Transport"
    /// preference. Persisted across launches so `AppServices` can
    /// auto-restart the tunnel without waiting for the user to
    /// re-toggle every relaunch. Written by the Settings toggle and
    /// by the onboarding step; read by `AppServices.initialize()`.
    public static let tunnelEnabledKey = "com.columba.tunnelEnabled"
}

/// Append-only log file in the App Group container. Both the app and
/// the Network Extension can write to it; the extension uses it
/// because `os.log` from extensions is hard to surface (no
/// `NSLog`-equivalent that lands in the app's `DiagLog`). The app
/// can copy it into its Documents/diag.log on next foreground for
/// `xcrun devicectl device copy from` retrieval.
public enum ExtensionDiagLog {
    /// Compute on every call so a transient `containerURL` failure
    /// at static-init time doesn't permanently disable logging.
    /// Writes under `Library/Caches/` which is already auto-created
    /// in the App Group container — writing to the container root
    /// silently fails on at least some iOS versions when invoked
    /// from a Network Extension process.
    private static func resolveLogURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        let cachesDir = containerURL.appendingPathComponent("Library/Caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        return cachesDir.appendingPathComponent("ext_diag.log")
    }

    public static func log(_ message: String) {
        // Mirror to NSLog so it shows up in ASL / Console.app even
        // if the file write below silently fails.
        NSLog("%@", message)

        guard let url = resolveLogURL() else {
            NSLog("[ExtensionDiagLog] containerURL returned nil — App Group not accessible?")
            return
        }
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let fh = try FileHandle(forWritingTo: url)
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                try data.write(to: url)
            }
        } catch {
            NSLog("[ExtensionDiagLog] write failed: %@", "\(error)")
        }
    }

    /// Path on disk — useful so the app can copy this into its
    /// Documents container for `devicectl copy from` retrieval.
    public static var path: String? { resolveLogURL()?.path }
}


/// Interface tag identifying which network interface a frame arrived on.
public enum FrameInterfaceTag: UInt8 {
    case tcp = 0x01
    case auto = 0x02
}

/// A frame read from the shared queue, tagged with its source interface.
public struct QueuedFrame {
    public let interfaceTag: UInt8
    public let data: Data
}

/// File-backed frame queue for IPC between Network Extension and main app.
///
/// Uses POSIX file locking to prevent corruption when both processes access
/// the file simultaneously. Frames are length-prefixed for reliable parsing.
///
/// The queue file lives in the App Group shared container so both the main
/// app and the Network Extension can access it.
public final class SharedFrameQueue: @unchecked Sendable {

    // MARK: - Constants

    /// Header size: 4 bytes length + 1 byte interface tag
    private static let headerSize = 5

    // MARK: - Properties

    /// Path to the queue file in the shared container.
    private let fileURL: URL

    /// File descriptor for POSIX locking (kept open for the lifetime of this object).
    private var fd: Int32 = -1

    // MARK: - Initialization

    /// Create a shared frame queue in the given App Group container.
    ///
    /// - Parameter appGroupIdentifier: The App Group identifier (e.g., "group.network.columba.Columba")
    public init(appGroupIdentifier: String) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            // Fallback to tmp if app group not available (shouldn't happen in production)
            self.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("frame_queue")
            return
        }
        self.fileURL = containerURL.appendingPathComponent("frame_queue")
    }

    deinit {
        if fd >= 0 {
            close(fd)
        }
    }

    // MARK: - Public API

    /// Append a frame to the queue (called by Network Extension).
    ///
    /// Thread-safe via POSIX file locking. Multiple concurrent appenders
    /// are supported but serialized by the lock.
    ///
    /// - Parameters:
    ///   - frame: Raw frame data
    ///   - interfaceTag: Which interface this frame arrived on
    public func append(frame: Data, interfaceTag: UInt8) {
        let length = UInt32(frame.count)
        var header = Data(count: Self.headerSize)
        // 4-byte big-endian length
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)
        // 1-byte interface tag
        header[4] = interfaceTag

        withFileLock {
            let fh: FileHandle
            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
                fh = handle
            } else {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
                fh = handle
            }
            fh.seekToEndOfFile()
            fh.write(header)
            fh.write(frame)
            fh.closeFile()
        }
    }

    /// Read all queued frames and clear the queue (called by main app).
    ///
    /// Atomically reads all frames and truncates the file. If the file
    /// is corrupted or partially written, skips malformed frames.
    ///
    /// - Returns: Array of queued frames, possibly empty
    public func readAllAndClear() -> [QueuedFrame] {
        var frames: [QueuedFrame] = []

        withFileLock {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  !data.isEmpty else {
                return
            }

            // Parse frames
            var offset = 0
            while offset + Self.headerSize <= data.count {
                let length = Int(
                    (UInt32(data[offset]) << 24) |
                    (UInt32(data[offset + 1]) << 16) |
                    (UInt32(data[offset + 2]) << 8) |
                    UInt32(data[offset + 3])
                )
                let tag = data[offset + 4]
                offset += Self.headerSize

                guard offset + length <= data.count else {
                    // Truncated frame — stop parsing
                    break
                }

                let frameData = data[offset..<(offset + length)]
                frames.append(QueuedFrame(interfaceTag: tag, data: Data(frameData)))
                offset += length
            }

            // Truncate the file
            try? Data().write(to: fileURL, options: .atomic)
        }

        return frames
    }

    /// Check if there are any queued frames without reading them.
    ///
    /// - Returns: True if the queue file exists and is non-empty
    public var hasFrames: Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64 else { return false }
        return size > 0
    }

    // MARK: - File Locking

    /// Execute a closure while holding a POSIX exclusive file lock.
    ///
    /// Uses a separate lock file (.lock) to avoid conflicts with the data file.
    private func withFileLock(_ body: () -> Void) {
        let lockPath = fileURL.path + ".lock"

        // Ensure lock file exists
        if !FileManager.default.fileExists(atPath: lockPath) {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
        }

        let lockFd = Darwin.open(lockPath, O_RDWR)
        guard lockFd >= 0 else {
            // Can't get lock file — just run without lock (best effort)
            body()
            return
        }

        // Acquire exclusive lock (blocking)
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0
        _ = fcntl(lockFd, F_SETLKW, &fl)

        body()

        // Release lock
        fl.l_type = Int16(F_UNLCK)
        _ = fcntl(lockFd, F_SETLK, &fl)
        Darwin.close(lockFd)
    }
}
