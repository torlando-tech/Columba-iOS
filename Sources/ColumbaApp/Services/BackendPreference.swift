//
//  BackendPreference.swift
//  ColumbaApp
//
//  Runtime selection of the active RNS backend.
//

import Foundation

/// The one runtime architecture compiled for an app target.
///
/// `COLUMBA_RUNTIME_PYTHON` and `COLUMBA_RUNTIME_MODEL_B` are the canonical
/// flavor flags. Until the dedicated targets land, the existing
/// `COLUMBA_BACKEND_SWIFT` configuration remains as a compatibility fallback;
/// an unflagged standard build remains Python. Once either canonical flag is
/// present, persisted backend preferences have no role in this selection.
enum RuntimeFlavor: Equatable {
    case python
    case modelB

    static func resolve(persistedUseSwiftBackend: Bool?) -> RuntimeFlavor {
        // Deliberately ignored. Runtime architecture is a build property, not a
        // user preference; retaining the argument makes that boundary directly
        // testable while the legacy preference is removed in the next refactor.
        _ = persistedUseSwiftBackend

        #if COLUMBA_RUNTIME_PYTHON && COLUMBA_RUNTIME_MODEL_B
        #error("Exactly one Columba runtime flavor may be compiled")
        #elseif COLUMBA_RUNTIME_MODEL_B
        return .modelB
        #elseif COLUMBA_RUNTIME_PYTHON
        return .python
        #elseif COLUMBA_BACKEND_SWIFT
        return .modelB
        #else
        return .python
        #endif
    }
}

/// Persisted choice of which RNS engine `BackendFactory.make()` constructs:
/// the embedded-Python reference stack (`PythonRNSBackend`) or the native
/// Swift reticulum-swift/LXMF-swift port (`SwiftRNSBackend`). Both are compiled
/// and linked into every build, so this is a pure runtime switch — the
/// Settings → Advanced → Network Backend control writes it, `BackendFactory`
/// reads it at stack-init time.
///
/// The switch takes effect on the **next app launch**: the backend is built
/// exactly once during `AppServices.initialize`, and neither the embedded
/// CPython interpreter (a process-global singleton) nor the Swift RNS stack
/// can be torn down and rebuilt in place reliably on iOS — the same constraint
/// that makes `restartPythonBackend()` defer to relaunch rather than restart
/// the interpreter live.
///
/// Stored in the App Group suite (`SharedDefaults`) so it survives relaunch and
/// is visible to the Network Extension, mirroring `transport_enabled`.
enum BackendPreference {
    private static let key = "useSwiftBackend"

    /// Compile-time runtime architecture for this app target. The persisted
    /// legacy backend preference is passed only to make its non-influence an
    /// explicit, testable contract.
    static var runtimeFlavor: RuntimeFlavor {
        runtimeFlavor(defaults: SharedDefaults.suite)
    }

    static func runtimeFlavor(defaults: UserDefaults) -> RuntimeFlavor {
        RuntimeFlavor.resolve(
            persistedUseSwiftBackend: defaults.object(forKey: key) as? Bool
        )
    }

    /// Whether the app runs as the thin **Model B** proxy — the Network
    /// Extension owns the `lxmf.delivery` node and the app marshals node-owning
    /// ops to it over IPC (`ProxyRnsBackend`) — rather than a destination-owning
    /// local backend.
    ///
    /// This is **not** a user setting. It's tied to the build: the NE is only
    /// compiled in on the Swift build (`ENABLE_NETWORK_EXTENSION`, the same
    /// `Debug-Swift` / `Release-Swift` configs that define `COLUMBA_BACKEND_SWIFT`),
    /// and on that build Model B is the *sole* architecture — there is no toggle
    /// and no opt-out. On the standard build the NE isn't present, so the app runs
    /// a foreground node (embedded-Python or local Swift).
    ///
    /// INVARIANT: when `true`, the NE is the SINGLE owner of `lxmf.delivery`
    /// (see `BackendFactory.make()` / `ProxyRnsBackend`). The NE mirrors this via
    /// `NEReticulumNode.modelBNodeEnabled`, which is likewise hardcoded `true`
    /// (the extension only exists to be the node). Hardcoding both sides also
    /// removes the cross-process flag race that used to leave the NE in sniff
    /// mode while the app came up as the proxy.
    static var modelB: Bool {
        runtimeFlavor == .modelB
    }

    /// Default when the user has never chosen explicitly. The `Columba-Swift`
    /// scheme (`COLUMBA_BACKEND_SWIFT`) starts on the Swift backend; the stock
    /// scheme starts on embedded Python.
    static var buildDefaultIsSwift: Bool {
        #if COLUMBA_BACKEND_SWIFT
        return true
        #else
        return false
        #endif
    }

    /// Whether the native Swift backend is selected (vs embedded Python).
    /// Falls back to the build-flag default until the user picks explicitly.
    static var isSwift: Bool {
        get {
            #if COLUMBA_BACKEND_SWIFT
            // Swift-only build: the embedded Python wheels are stripped at
            // build time, so Python can't run. Force Swift regardless of any
            // stored pref — a `useSwiftBackend=false` value can linger in the
            // shared App Group suite from a prior standard build, and honoring
            // it here would build PythonRNSBackend and hang on start(). The
            // Settings toggle is also hidden on this build (see SettingsView).
            return true
            #else
            guard let stored = SharedDefaults.suite.object(forKey: key) as? Bool else {
                return buildDefaultIsSwift
            }
            return stored
            #endif
        }
        set { SharedDefaults.suite.set(newValue, forKey: key) }
    }
}
