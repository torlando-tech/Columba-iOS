//
//  NEPythonRNS.swift
//  ColumbaNetworkExtension
//
//  The in-NE Python RNS engine (contract 15: the first `NodeEngine`
//  conformance that drives the reference implementation through the seam).
//
//  This is the heart of "the NE is the sole place Reticulum runs": it drives
//  the live Python RNS runtime (the same `rns_bridge.py` the app's in-process
//  backend used) through the embedded CPython (`NEPythonRuntime.callBridge`).
//  The C++ microReticulum node (`NEReticulumNode`) is no longer the runtime -
//  Python RNS is the single runtime in the NE.
//
//  It is intentionally a THIN adapter over `rns_bridge`: every operation is
//  one JSON call into Python, and the Python side owns all RNS/LXMF state
//  (the same module the app shipped, so behavior is byte-for-byte what the app
//  already validated). The Swift side only maps the IPC `ProxyRequest` /
//  `ProxyResponse` surface onto `rns_bridge` functions.
//
//  COLLISION RULE (hard): this file imports ONLY Foundation (+ the NE-local
//  `NEPythonRuntime`, `ExtensionDiagLog`, `AppGroupPaths`). It must NOT import
//  RNSAPI / ReticulumSwift / LXMFSwift.
//

import Foundation
import Security

/// The `NodeEngine`-style adapter over the in-NE Python RNS runtime.
///
/// One instance per NE boot. `PacketTunnelProvider` holds it and routes the
/// app's `ProxyRequest` IPC to it (replacing the old `NEReticulumNode`
/// dispatch). It is `@unchecked Sendable`: all state is either immutable or
/// guarded by a lock, and every Python call runs on the GIL inside
/// `NEPythonRuntime.callBridge`.
final class NEPythonRNS: @unchecked Sendable {

    /// True once `start()` has brought the Python RNS node up.
    private(set) var isRunning = false
    private let stateLock = NSLock()

    /// The shared keychain group the app stored the identity in (resolved once,
    /// so the keychain access-group probe isn't repeated on every start).
    private var cachedAccessGroup: String?

    private init() {}

    /// The engine instance owned by the running NE. Constructed lazily so the
    /// CPython interpreter is only touched from the tunnel provider's tasks.
    static let shared = NEPythonRNS()

    // MARK: - Identity (shared keychain, Foundation-only read)
    //
    // The app stores the raw 64-byte RNS private-key blob as a
    // kSecClassGenericPassword item under service "com.columba.identity" /
    // account "reticulum-identity" in the SHARED keychain access group
    // (AppServices saves it there). We read the SAME item here (mirroring the
    // read the old NEReticulumNode did) so the Python engine starts with the
    // app's identity, without importing RNSAPI.

    private static let keychainService = "com.columba.identity"
    private static let keychainAccount = "reticulum-identity"
    private static let keychainGroupSuffix = "network.columba.Columba.shared"

    /// Read the app's shared identity blob (raw private-key bytes), or nil when
    /// the app hasn't created one yet (first launch) - the caller treats that
    /// as "not ready" and retries.
    func loadSharedIdentityBytes() -> Data? {
        let group = resolvedSharedKeychainGroup()
        guard let group else {
            ExtensionDiagLog.log("[NE-PY-RNS] shared keychain group unresolved - no identity")
            return nil
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecAttrAccessGroup as String: group,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else {
                ExtensionDiagLog.log("[NE-PY-RNS] keychain identity item present but empty")
                return nil
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            ExtensionDiagLog.log("[NE-PY-RNS] keychain identity read failed (OSStatus=\(item == nil ? "n/a" : "present"))")
            return nil
        }
    }

    /// The shared keychain access group, resolved at runtime (no hardcoded team
    /// prefix - no deployment PII). Prefers the value the app resolved + shared
    /// via App-Group UserDefaults; falls back to probing (mirrors the old
    /// NEReticulumNode resolution).
    private func resolvedSharedKeychainGroup() -> String? {
        if let cached = cachedAccessGroup, !cached.isEmpty { return cached }
        if let shared = UserDefaults(suiteName: appGroupIdentifier)?
            .string(forKey: "resolvedSharedKeychainGroup"), !shared.isEmpty {
            cachedAccessGroup = shared
            return shared
        }
        guard let prefix = keychainAccessGroupPrefix() else { return nil }
        let group = "\(prefix).\(Self.keychainGroupSuffix)"
        cachedAccessGroup = group
        return group
    }

    /// Probe the keychain for the team-id prefix of this bundle's access group
    /// (a transient seed item, deleted after reading - mirrors
    /// AppServices.keychainAccessGroupPrefix).
    private func keychainAccessGroupPrefix() -> String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "columba.bundleSeedProbe",
            kSecAttrService as String: "columba.bundleSeedProbe",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(probe as CFDictionary, &result)
        if status == errSecItemNotFound {
            status = SecItemAdd(probe as CFDictionary, &result)
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "columba.bundleSeedProbe",
            kSecAttrService as String: "columba.bundleSeedProbe",
        ] as CFDictionary)
        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = group.components(separatedBy: ".").first,
              !prefix.isEmpty else { return nil }
        return prefix
    }

    // MARK: - Node lifecycle

    /// Bring the Python RNS node up. Returns the local info JSON
    /// (`{"identity_hash":..., "destination_hash":...}`) on success, or nil
    /// when the app hasn't created a shared identity yet (the caller replies
    /// `.unsupported` so the app retries). Idempotent at the Python level
    /// (`rns_bridge.start` returns the existing local_info if already up).
    ///
    /// `displayName` rides in the `.start` request; it is passed to
    /// `rns_bridge.start` so the startup announce carries it.
    func start(displayName: String) -> String? {
        guard NEPythonRuntime.shared.state == .running else {
            // CPython not initialized yet (shouldn't happen - startTunnel boots
            // it) - try to init synchronously; if that fails we're not ready.
            switch NEPythonRuntime.shared.start() {
            case .success:
                break
            case .failure(let err):
                ExtensionDiagLog.log("[NE-PY-RNS] start: python not ready (init failed: \(err.localizedDescription))")
                return nil
            }
        }
        guard let identity = loadSharedIdentityBytes() else {
            ExtensionDiagLog.log("[NE-PY-RNS] start: no shared identity yet - not ready")
            return nil
        }
        let configDir = Self.sharedConfigDir()
        // rns_bridge.start requires identity_path even when identity_bytes is
        // supplied (the bytes win; the path is a fallback). Co-locate it in the
        // shared config dir (the app also writes identity.bin there).
        let identityPath = (configDir as NSString).appendingPathComponent("identity.bin")
        let kwargs: [String: Any] = [
            "config_dir": configDir,
            "identity_path": identityPath,
            "display_name": displayName,
            "identity_bytes": Self.b64Wrapper(identity),
        ]
        guard let payload = Self.payload(kwargs: kwargs),
              let out = NEPythonRuntime.shared.callBridge("start", payload: payload) else {
            ExtensionDiagLog.log("[NE-PY-RNS] start: bridge call failed to build/dispatch")
            return nil
        }
        guard let (ok, result, error) = Self.parse(out) else {
            ExtensionDiagLog.log("[NE-PY-RNS] start: unparseable bridge reply")
            return nil
        }
        if !ok {
            ExtensionDiagLog.log("[NE-PY-RNS] start failed: \(error ?? "(no error)")")
            return nil
        }
        stateLock.lock(); isRunning = true; stateLock.unlock()
        ExtensionDiagLog.log("[NE-PY-RNS] start OK: \(result ?? "")")
        return result
    }

    func stop() {
        guard NEPythonRuntime.shared.state == .running else { return }
        _ = NEPythonRuntime.shared.callBridge("stop", payload: Self.payload(kwargs: [:]) ?? "{}")
        stateLock.lock(); isRunning = false; stateLock.unlock()
        ExtensionDiagLog.log("[NE-PY-RNS] stop")
    }

    // MARK: - Bridge op wrappers (used by PacketTunnelProvider.dispatchPython)

    /// `rns_bridge.announce(display_name)` → `{ok, reason}`.
    func announce(displayName: String) -> [String: Any]? {
        Self.dict(from: call("announce", kwargs: ["display_name": displayName]))
    }

    /// `rns_bridge.announce_telephony(display_name)` → `{ok, reason}`.
    func announceTelephony(displayName: String) -> [String: Any]? {
        Self.dict(from: call("announce_telephony", kwargs: ["display_name": displayName]))
    }

    /// `rns_bridge.status()` → the snake_case status snapshot JSON the app decodes.
    /// Returns the raw result JSON string (forwarded directly to the IPC).
    func status() -> String? {
        call("status", kwargs: [:])
    }

    /// `rns_bridge.local_info()` → `{identity_hash, destination_hash}`.
    func localInfo() -> String? {
        call("local_info", kwargs: [:])
    }

    /// `rns_bridge.drain_events()` → `[{kind, ...}, ...]`. Non-announce events are
    /// dropped by the caller; returning nil here means the bridge call failed.
    func drainEvents() -> [[String: Any]]? {
        guard let json = call("drain_events", kwargs: [:]),
              let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        return arr
    }

    /// `rns_bridge.persist()` → `{ok, ...}`.
    func persist() -> [String: Any]? {
        Self.dict(from: call("persist", kwargs: [:]))
    }

    /// `rns_bridge.send_opportunistic(...)` → `{ok, reason, message_hash?}`.
    func lxmfSend(destHashHex: String, content: String, method: String, fieldsHex: String) -> [String: Any]? {
        let kwargs: [String: Any] = [
            "dest_hash_hex": destHashHex,
            "content": content,
            "method": method,
            "fields_hex": fieldsHex,
        ]
        return Self.dict(from: call("send_opportunistic", kwargs: kwargs))
    }

    // MARK: - Ops

    /// Call a `rns_bridge` op that returns a JSON dict, forwarding the raw JSON.
    /// Returns the Python result JSON string, or nil on a bridge-level failure.
    private func call(_ fn: String, kwargs: [String: Any]) -> String? {
        guard NEPythonRuntime.shared.state == .running else { return nil }
        guard let payload = Self.payload(kwargs: kwargs),
              let out = NEPythonRuntime.shared.callBridge(fn, payload: payload) else {
            return nil
        }
        guard let (ok, result, error) = Self.parse(out) else {
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn): unparseable reply")
            return nil
        }
        if !ok {
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn) failed: \(error ?? "(no error)")")
            return nil
        }
        return result
    }

    // MARK: - Shared config dir (NE-side)

    /// The App-Group-shared RNS config dir for the app's current identity.
    /// The app writes `<dir>/config` (+ `identity.bin`) here; the NE reads it.
    /// Returns a tmp fallback when the App-Group container is unavailable
    /// (unsigned build) so `start` degrades instead of crashing.
    static func sharedConfigDir() -> String {
        // Resolve the identity hash from the shared keychain blob so we key the
        // dir the same way the app does (python-<rawIdentityHashHex>). We compute
        // the RNS identity hash in Python (RNS.Identity.from_bytes(...).hash) to
        // avoid importing RNSAPI - but that requires a Python call. Cheaper: the
        // app also persists the raw hex it used, under App-Group defaults.
        if let hex = UserDefaults(suiteName: appGroupIdentifier)?
            .string(forKey: "rnsConfigIdentityHashHex"), !hex.isEmpty {
            if let url = AppGroupPaths.rnsConfigDirectoryURL(identityHashHex: hex) {
                return url.path
            }
        }
        // Fallback: a shared, identity-agnostic dir the app also writes when it
        // can't key per-identity. (Rare - only when the hex default is absent.)
        if let container = AppGroupPaths.containerURL() {
            let dir = container.appendingPathComponent("Columba", isDirectory: true)
                .appendingPathComponent("python-current", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.path
        }
        // No App-Group container at all (unsigned): tmp fallback.
        return NSTemporaryDirectory()
    }

    // MARK: - JSON helpers

    /// Wrap raw bytes as the `{"__b64__": ...}` marker the Python `_dec` decodes
    /// back to `bytes`.
    private static func b64Wrapper(_ data: Data) -> [String: String] {
        ["__b64__": data.base64EncodedString()]
    }

    /// Build the `{"args":[], "kwargs":{...}}` payload JSON for `callBridge`.
    private static func payload(args: [Any] = [], kwargs: [String: Any]) -> String? {
        let obj: [String: Any] = ["args": args, "kwargs": kwargs]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Parse the `{"ok":.., "result"|"error":..}` reply. `result` is itself a
    /// JSON string (the op's JSON-serializable return).
    private static func parse(_ out: String) -> (ok: Bool, result: String?, error: String?)? {
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let ok = obj["ok"] as? Bool ?? false
        return (ok, obj["result"] as? String, obj["error"] as? String)
    }

    /// Parse a `call` result (the op's JSON-serializable return) into a dict, or
    /// nil when it isn't a JSON object (or the call returned nil).
    private static func dict(from result: String?) -> [String: Any]? {
        guard let result,
              let data = result.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return obj
    }
}
