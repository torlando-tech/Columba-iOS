//
//  ExtensionDiagLog.swift
//  Columba Shared
//
//  Append-only diagnostic logger for the Network Extension, backed by a file in
//  the App-Group container (`ext-diag.log`). The NE is sandboxed and its
//  unified-log output does not reliably reach the host over WiFi-only devices,
//  so the NE writes its diagnostics here; the main app copies this file into its
//  Documents directory on launch (`copyExtensionDiagToDocuments()`), making it
//  retrievable via `devicectl ... copy from --domain-type appDataContainer`.
//
//  ── NO-PII CONTRACT (HARD RULE) ──────────────────────────────────────────────
//  Lines written here carry ENVELOPE / METADATA ONLY. They MUST NOT contain:
//    • message plaintext or any frame / packet payload bytes,
//    • identity material (private keys, full identity hashes),
//    • LAN IPs, relay host:port, or on-device home / container paths.
//  Destination hashes are logged as SHORT PREFIXES (≤ 8 hex chars) only. TCP
//  relays are referenced abstractly (e.g. "TCP relay") — never host or port.
//  This file is the durable observability channel for on-device NE verification;
//  keeping it PII-free is the entire point of this phase.
//
//  This file imports ONLY Foundation and is compiled into BOTH the ColumbaApp
//  and ColumbaNetworkExtension targets. Like `SharedFrameQueue`, it must stay
//  free of ReticulumSwift / RNSAPI so it compiles in the NE target (which links
//  neither).
//

import Foundation

/// Append-only, thread-safe diagnostic logger writing to the App-Group container
/// file `ext-diag.log`. Mirrors `DiagLog` (the app's Documents/diag.log logger)
/// but targets the shared container so the sandboxed Network Extension can write
/// it and the host app can copy it out.
///
/// NO-PII: only envelope/metadata — see the file header contract.
public enum ExtensionDiagLog {

    /// App-Group container file the NE appends to and the app reads back.
    /// Defined here (not derived from a Reticulum type) so the file stays
    /// Foundation-only and usable from the NE target.
    public static let fileURL: URL? = {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return containerURL.appendingPathComponent("ext-diag.log")
    }()

    /// Serializes appends/reads/clears so concurrent NE callbacks (TCP receive,
    /// Darwin-notification config reloads, NWConnection state handlers — all on
    /// different queues) can't interleave a write. A lock (not a serial queue) so
    /// `log` stays synchronous, matching `DiagLog.log`'s call-site ergonomics.
    private static let lock = NSLock()

    /// Append one ISO8601-timestamped line. Creates the file on first write and
    /// sets `completeUntilFirstUserAuthentication` protection so the NE can keep
    /// writing while the device is locked-after-first-unlock (consistent with the
    /// deliver-while-locked posture). Best-effort: failures are swallowed (this is
    /// a diagnostics side-channel and must never destabilize the NE).
    ///
    /// NO-PII: callers must pass envelope/metadata only — see the file header.
    public static func log(_ message: String) {
        // Keep ASL/unified-log output too (useful over USB), mirroring DiagLog.
        NSLog("[EXT] %@", message)

        guard let fileURL else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let fh = try? FileHandle(forWritingTo: fileURL) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            // `createFile` lets us stamp file protection atomically with creation
            // so there's no window where the file exists at default protection.
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: data,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
        // Re-assert protection on every append: an empty/zero-length file created
        // by another process (or a prior run) may carry default protection, which
        // would block writes on a locked device. Cheap and idempotent.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }

    /// Truncate the log to empty. Used by the host before a fresh capture run.
    public static func clear() {
        guard let fileURL else { return }
        lock.lock()
        defer { lock.unlock() }
        try? Data().write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }

    /// Read back the full log text (for the host copy-out / inspection). Returns
    /// an empty string when the container or file is unavailable.
    public static func recentText() -> String {
        guard let fileURL else { return "" }
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}
