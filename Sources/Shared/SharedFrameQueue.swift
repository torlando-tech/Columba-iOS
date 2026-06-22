//
//  SharedFrameQueue.swift
//  Columba Shared
//
//  Lock-free append-only queue backed by a shared file in the App Group container.
//  One process appends frames; the other reads and clears them.
//
//  Frame format: [4-byte length (big-endian)][1-byte interface tag][N-byte frame data]
//  Interface tags: 0x01 = TCP, 0x02 = Auto, 0x10 = BLE mesh radio, 0x11 = RNode radio
//
//  Two named directional queues live in the App Group container (Model B IPC bridge):
//
//    • `e2a` (NE→app): frames the Network Extension produces. Historically this
//      carried inbound TCP/Auto frames for the app to inject into its transport
//      (#57); under Model B it also carries NE-originated frames that the app
//      must transmit on a radio (tagged with the target radio selector). Backed
//      by the original `frame_queue` file name for back-compat — `init` defaults
//      to that name so existing call sites (`PacketTunnelProvider`,
//      `ExtensionFrameReader`) keep working unchanged.
//
//    • `a2e` (app→NE): radio-received frames the app forwards into the NE's RNS
//      instance so the NE is the single RNS node reachable over both TCP and
//      radio. Backed by the `frame_queue_a2e` file name.
//
//  This file imports ONLY Foundation and is compiled into BOTH the ColumbaApp
//  and ColumbaNetworkExtension targets. It must stay free of ReticulumSwift /
//  RNSAPI so it can compile in the NE target (which does not link those). The
//  `NetworkInterface`-conforming bridge lives in a separate file
//  (`AppGroupBridgeInterface.swift`) that imports ReticulumSwift.
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

    /// Darwin notification posted by the extension when frames have
    /// been written to the NE→app (`e2a`) `SharedFrameQueue`. The app's
    /// `ExtensionFrameReader` observes this to drain the queue.
    public static let packetReadyNotificationName = "network.columba.packetReady"

    /// Darwin notification posted by the app when radio-received frames
    /// have been written to the app→NE (`a2e`) `SharedFrameQueue`. The
    /// extension observes this to drain the queue and inject the frames
    /// into its RNS transport via `AppGroupBridgeInterface`. (Wiring of
    /// the observer on the NE side is Track A5.)
    public static let radioFrameReadyNotificationName = "network.columba.radioFrameReady"

    /// Darwin notification posted when a `BLEDriverSeamMessage` is written to the
    /// NE→app BLE-seam queue (`bleSeamN2A`). The app's seam transport observes it.
    public static let bleSeamN2ANotificationName = "network.columba.bleSeam.n2a"
    /// Darwin notification posted when a `BLEDriverSeamMessage` is written to the
    /// app→NE BLE-seam queue (`bleSeamA2N`). The NE's seam transport observes it.
    public static let bleSeamA2NNotificationName = "network.columba.bleSeam.a2n"

    /// Darwin notification posted when an `RNodeSeamMessage` is written to the
    /// NE→app RNode-seam queue (`rnodeSeamN2A`). The app's RNode server observes it.
    public static let rnodeSeamN2ANotificationName = "network.columba.rnodeSeam.n2a"
    /// Darwin notification posted when an `RNodeSeamMessage` is written to the
    /// app→NE RNode-seam queue (`rnodeSeamA2N`). The NE's seam transport observes it.
    public static let rnodeSeamA2NNotificationName = "network.columba.rnodeSeam.a2n"

    /// Shared UserDefaults key holding the JSON-encoded interface
    /// configuration array (full `InterfaceEntity` objects). Both the
    /// app's `InterfaceRepository` and the extension's
    /// `loadInterfaceConfigs` read from this key.
    public static let interfacesKey = "com.columba.interfaces"

    /// Shared UserDefaults key holding the JSON-encoded `RNodeSeamConfig` for the
    /// Model B RNode interface (device name + radio params), or absent when no RNode
    /// is enabled. Written by the app (which owns the full `RNodeConfig`), read by the
    /// NE (which is RNSAPI-free and maps it to reticulum-swift's `RadioConfig`).
    public static let rnodeConfigKey = "com.columba.rnodeConfig"

    /// Darwin notification posted by the app when the RNode config (`rnodeConfigKey`)
    /// changes (enabled / disabled / re-tuned). The NE observes it to (re)build or tear
    /// down its `RNodeInterface`.
    public static let rnodeConfigChangedNotificationName = "network.columba.rnodeConfigChanged"

    /// Shared UserDefaults key holding the JSON-encoded `PropagationSeamConfig` (the
    /// selected propagation node hash + stamp cost + sync interval/enabled), or absent
    /// when none is selected. Written by the app (`PropagationNodeManager`, Model B
    /// only), read by the NE which wires it onto its in-NE `LXMRouter`.
    public static let propagationConfigKey = "com.columba.propagationConfig"

    /// Darwin notification posted by the app when `propagationConfigKey` changes (PN
    /// selected/cleared, interval/enabled edited). The NE observes it to re-apply the PN
    /// on its router and restart its sync scheduler.
    public static let propagationConfigChangedNotificationName = "network.columba.propagationConfigChanged"

    /// Darwin notification posted by the app to ask the NE to run one immediate
    /// propagation sync (the "Sync Now" button — the app can't call the NE's router).
    public static let propagationSyncNowNotificationName = "network.columba.propagationSyncNow"

    /// Shared UserDefaults key holding the JSON-encoded `PropagationSyncStateSnapshot`
    /// the NE writes as a sync progresses (phase / progress / counts / error). The app
    /// reads it to drive the in-app sync UI; Darwin carries no payload, hence this key.
    public static let propagationSyncStateKey = "com.columba.propagationSyncState"

    /// Darwin notification posted by the NE when `propagationSyncStateKey` updates. The
    /// app observes it to refresh `PropagationNodeManager.syncState` (the sync sheet).
    public static let propagationSyncStateChangedNotificationName = "network.columba.propagationSyncStateChanged"
}

/// Interface tag identifying which network interface a frame is associated with.
///
/// For `e2a` (NE→app) inbound frames this is the interface the frame arrived on
/// inside the NE (`tcp` / `auto`). For `e2a` NE-originated radio transmissions and
/// for `a2e` (app→NE) radio receptions, this selects which radio the frame came
/// from / should be transmitted on (`bleMesh` / `rnode`).
public enum FrameInterfaceTag: UInt8 {
    case tcp = 0x01
    case auto = 0x02
    /// BLE-mesh radio (Columba's GATT mesh transport).
    case bleMesh = 0x10
    /// RNode radio (LoRa over BLE/serial RNode hardware).
    case rnode = 0x11
    /// A codec'd `BLEDriverSeamMessage` on the Model B BLE driver seam (the
    /// dedicated `bleSeam*` queues carry only these, so the tag is uniform).
    case bleControl = 0x20
    /// A codec'd `RNodeSeamMessage` on the Model B RNode serial seam (the dedicated
    /// `rnodeSeam*` queues carry only these, so the tag is uniform).
    case rnodeControl = 0x21
}

/// File names for the two directional App-Group frame queues.
///
/// `default_` (= `frame_queue`) preserves the original single-queue file name so
/// existing NE→app call sites keep working without migration (#57). `a2e` is the
/// new app→NE radio-ingest queue introduced for the Model B IPC bridge.
public enum SharedFrameQueueName {
    /// NE→app direction. Original file name — keep for back-compat.
    public static let e2a = "frame_queue"
    /// app→NE direction (radio-received frames forwarded into the NE's RNS).
    public static let a2e = "frame_queue_a2e"

    // Model B BLE driver seam (dedicated queues, separate from the radio-frame
    // a2e/e2a above so the BLE control/data stream never intermixes with — or
    // double-drains against — `AppGroupBridgeInterface`).
    /// NE→app: `BLEDriver` commands + `sendFragment` (app drains).
    public static let bleSeamN2A = "ble_seam_n2a"
    /// app→NE: driver stream events + `receivedFragment` + reqId results (NE drains).
    public static let bleSeamA2N = "ble_seam_a2n"

    // Model B RNode serial seam (dedicated queues, separate from the BLE seam above
    // and the radio-frame a2e/e2a).
    /// NE→app: RNode transport commands (connect / send / disconnect). App drains.
    public static let rnodeSeamN2A = "rnode_seam_n2a"
    /// app→NE: RNode transport events (dataReceived / stateChanged). NE drains.
    public static let rnodeSeamA2N = "rnode_seam_a2n"
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
    /// - Parameters:
    ///   - appGroupIdentifier: The App Group identifier (e.g., "group.network.columba.Columba")
    ///   - name: Queue file name within the container. Defaults to
    ///     `SharedFrameQueueName.e2a` (`"frame_queue"`) for back-compat with
    ///     the original single NE→app queue (#57). Pass
    ///     `SharedFrameQueueName.a2e` for the app→NE radio-ingest queue. Each
    ///     name gets its own backing file and its own `.lock` file, so the two
    ///     directions never contend on the same POSIX lock.
    public init(appGroupIdentifier: String, name: String = SharedFrameQueueName.e2a) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            // Fallback to tmp if app group not available (shouldn't happen in production)
            self.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            return
        }
        self.fileURL = containerURL.appendingPathComponent(name)
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
    @discardableResult
    public func append(frame: Data, interfaceTag: UInt8) -> Bool {
        let length = UInt32(frame.count)
        var header = Data(count: Self.headerSize)
        // 4-byte big-endian length
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)
        // 1-byte interface tag
        header[4] = interfaceTag

        var wrote = false
        withFileLock {
            let fh: FileHandle
            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
                fh = handle
            } else {
                // Pin protection so locked-state IPC keeps working even if the app later
                // adopts a stricter default-data-protection class (matches ExtensionDiagLog).
                FileManager.default.createFile(
                    atPath: fileURL.path, contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
                fh = handle
            }
            fh.seekToEndOfFile()
            fh.write(header)
            fh.write(frame)
            fh.closeFile()
            wrote = true
        }
        return wrote
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
            FileManager.default.createFile(
                atPath: lockPath, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
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
