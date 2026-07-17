import Foundation
import RNSAPI

/// Constructs the sole RNS backend for the target's compile-time runtime flavor.
/// `COLUMBA_RUNTIME_PYTHON` builds the shipping embedded-Python backend;
/// `COLUMBA_RUNTIME_MODEL_B` builds the thin proxy whose Network Extension owns
/// the destination. Every app and test-host configuration must define exactly
/// one canonical flavor flag (see `RuntimeFlavor`).
///
/// Selection is intentionally expressed with compile-time branches so each
/// target can eventually omit the other flavor's backend source entirely. A
/// persisted legacy UI preference never affects backend construction.
@available(iOS 17.0, macOS 14.0, *)
enum BackendFactory {
    /// Construct the active backend for this launch.
    ///
    /// - Parameter proxySend: the Model B IPC transport — an async
    ///   encode-send-receive closure (wrapping `NETunnelProviderSession
    ///   .sendProviderMessage`; supplied by `TunnelManager.proxySend`). Only used
    ///   by the `COLUMBA_RUNTIME_MODEL_B` flavor; pass `nil` (the default) when no
    ///   tunnel session is available. With `nil`, the proxy is still constructed
    ///   using a closure that always returns `nil` (every operation then degrades
    ///   to an IPC-failure / not-ready), keeping construction total.
    static func make(proxySend: (@Sendable (Data) async -> Data?)? = nil) -> any RnsBackend {
        #if COLUMBA_RUNTIME_PYTHON && COLUMBA_RUNTIME_MODEL_B
        #error("Exactly one Columba runtime flavor may be compiled")
        #elseif COLUMBA_RUNTIME_PYTHON
        DiagLog.log("[BACKEND] active=python flavor=shipping")
        return PythonRNSBackend()
        #elseif COLUMBA_RUNTIME_MODEL_B
        // The NE is the single owner of `lxmf.delivery`; this app process must
        // never construct a destination-owning Python or Swift backend.
        DiagLog.log("[BACKEND] active=proxy flavor=modelB")
        let send: @Sendable (Data) async -> Data? = proxySend ?? { _ in nil }
        return ProxyRnsBackend(send: send)
        #else
        #error("Exactly one Columba runtime flavor must be compiled")
        #endif
    }
}
