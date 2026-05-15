import Foundation
import RNSAPI

/// Phase 1c skeleton: the root `RNSBackend` implementation that wraps the
/// canonical Mark Qvist Python RNS + LXMF embedded via BeeWare's
/// Python-Apple-support.
///
/// Mirrors `ChaquopyRnsBackend.kt` in Columba Android's `rns-backend-py`,
/// minus the AIDL boundary (iOS runs everything in-process). Six sub-impls
/// (`PythonRNSCore`, `PythonRNSLxmf`, `PythonRNSTelephony`,
/// `PythonRNSTelemetry`, `PythonRNSNomadnet`, `PythonRNSTransportAdmin`)
/// share one `PythonRNSRuntime` and one `PythonEventBridge` — those land
/// in subsequent commits as the protocol surfaces get ported.
///
/// This file is intentionally a skeleton; full implementation lands once
/// the `RNSAPI` protocol files are ported and we have something to
/// conform to.
public final class PythonRNSBackend: Sendable {
    public init() {
        // Phase 2 implementation lands here.
    }
}
