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
    static func make() -> any RnsBackend {
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
