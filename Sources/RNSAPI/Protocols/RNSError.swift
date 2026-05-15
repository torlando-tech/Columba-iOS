import Foundation

/// Typed error envelope for the Reticulum backend.
///
/// On Android this crosses an AIDL boundary between the UI process and a
/// dedicated `:reticulum` backend process, so it has a manual `Parcelable`
/// implementation. iOS doesn't have that boundary (everything runs in the
/// app process), so the Swift port is a plain `Error` enum with associated
/// values — same surface, no marshalling glue.
///
/// Most error cases have a typed variant so the UI can render a meaningful
/// message and choose recovery actions; truly novel failures fall through
/// to `.generic` with the original message and Python stack trace text
/// preserved for debugging.
///
/// Mirrors `RnsError.kt` in Columba Android's `rns-api`.
public enum RNSError: Error, Equatable {
    /// Unrecognised failure. `stackTraceText` is the formatted Python
    /// traceback for the originating exception. May be `nil` for client-side
    /// synthesized errors (e.g., timeout from outside the Python layer).
    case generic(message: String, stackTraceText: String?)

    /// Backend hasn't completed `initialize()` yet. Surfaced by any
    /// operation that requires the RNS stack to be running. UI should
    /// either wait for the network-status observer to flip to ready or
    /// surface a "still starting up" notice.
    case backendNotReady

    /// Identity wasn't found in the backend's identity store. `hashHex`
    /// is the truncated identity hash that was looked up.
    case identityNotFound(hashHex: String)

    /// Operation took longer than the caller's timeout budget.
    /// `operation` is a human-readable name of the call; `timeoutMs` is
    /// the timeout in milliseconds.
    case timeoutExceeded(operation: String, timeoutMs: Int64)

    /// Caller invoked a method whose corresponding capability is
    /// `BackendCapabilities.Support.unsupported`. Should only occur if a
    /// UI gate was missed — every UI surface that calls a capability-gated
    /// method is supposed to check the capability first via
    /// `BackendCapabilities`. The `feature` string names the specific
    /// capability path (e.g., `"performance.batteryProfileTuning"`).
    case featureUnsupported(feature: String)

    /// Telephony state machine refused the requested transition.
    /// `expected` is what the operation needed (e.g., `"ESTABLISHED"`);
    /// `actual` is the current state name. UI typically just shows a
    /// toast and re-renders the call card from the latest `VoiceCallState`.
    case callStateInvalid(expected: String, actual: String)

    /// NomadNet page request couldn't reach the destination or the
    /// destination returned a 404-equivalent. `destHash` is the target
    /// destination's hex hash; `path` is the requested page path
    /// (`"/page/index.mu"` etc.).
    case nomadnetPageNotFound(destHash: String, path: String)
}

extension RNSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .generic(let message, _):
            return message
        case .backendNotReady:
            return "Backend not ready"
        case .identityNotFound(let hashHex):
            return "Identity not found: \(hashHex)"
        case .timeoutExceeded(let operation, let timeoutMs):
            return "Timeout (\(timeoutMs)ms) on \(operation)"
        case .featureUnsupported(let feature):
            return "Feature unsupported: \(feature)"
        case .callStateInvalid(let expected, let actual):
            return "Invalid call state: expected \(expected), was \(actual)"
        case .nomadnetPageNotFound(let destHash, let path):
            return "NomadNet page not found: \(destHash)\(path)"
        }
    }
}
