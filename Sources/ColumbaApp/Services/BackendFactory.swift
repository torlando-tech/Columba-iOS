import Foundation
import RNSAPI

/// Constructs the active RNS backend. **Runtime-selected** via
/// `BackendPreference` (persisted, App-Group-backed): the embedded-Python
/// reference stack (`PythonRNSBackend`) or the native reticulum-swift/LXMF-swift
/// port (`SwiftRNSBackend`). Both are compiled and linked into every build, so
/// the Settings → Advanced → Network Backend control picks between them at
/// runtime; the `COLUMBA_BACKEND_SWIFT` build flag only sets the first-launch
/// default (see `BackendPreference.buildDefaultIsSwift`).
///
/// The rest of the app depends only on `any RnsBackend`, so swapping backends
/// never touches the UI or `AppServices`. The selection is read once here at
/// stack-init; changing it takes effect on the next app launch.
@available(iOS 17.0, macOS 14.0, *)
enum BackendFactory {
    /// Construct the active backend for this launch.
    ///
    /// - Parameter proxySend: the Model B IPC transport — an async
    ///   encode-send-receive closure (wrapping `NETunnelProviderSession
    ///   .sendProviderMessage`; supplied by `TunnelManager.proxySend`). Only used
    ///   when `BackendPreference.modelB` is on; pass `nil` (the default) when
    ///   Model B is off or no tunnel session is available. When Model B is on but
    ///   this is `nil`, the proxy is still constructed with a closure that always
    ///   returns `nil` (every op then degrades to an IPC-failure / not-ready),
    ///   keeping construction total — but in practice the caller wires the real
    ///   closure once A5c flips `modelB`.
    static func make(proxySend: (@Sendable (Data) async -> Data?)? = nil) -> any RnsBackend {
        // ── Track A5b / Model B (default OFF) ────────────────────────────────────
        // When enabled, the NE owns the single `lxmf.delivery` destination + node
        // (A5a's `NEReticulumNode`); the app must therefore NOT start a
        // destination-owning backend (`SwiftRNSBackend`/`PythonRNSBackend`) — doing
        // so would double-register the destination and double-deliver. The
        // always-the-node invariant is enforced HERE: we return EITHER the proxy OR
        // a destination-owning backend, never both. `ProxyRnsBackend` owns no
        // destination; it only marshals node ops to the NE. `modelB` defaults
        // `false`, so this branch is inert until A5c intentionally flips it.
        if BackendPreference.modelB {
            DiagLog.log("[BACKEND] active=proxy (Model B — NE owns the node)")
            let send: @Sendable (Data) async -> Data? = proxySend ?? { _ in nil }
            return ProxyRnsBackend(send: send)
        }

        // One unambiguous line stating which RNS engine is live this launch.
        // Every other backend log is prefixed `[RNS]` (engine-neutral, since
        // AppServices drives either backend through `any RnsBackend`), so grep
        // `[BACKEND]` to know which engine those lines came from. `pref` is the
        // raw stored value so a toggle-not-applying issue is visible here too.
        let isSwift = BackendPreference.isSwift
        DiagLog.log("[BACKEND] active=\(isSwift ? "swift" : "python") " +
            "(pref=\(String(describing: SharedDefaults.suite.object(forKey: "useSwiftBackend"))))")
        if isSwift {
            return SwiftRNSBackend()
        }
        return PythonRNSBackend()
    }
}
