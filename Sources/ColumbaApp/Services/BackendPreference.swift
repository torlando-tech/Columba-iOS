//
//  BackendPreference.swift
//  ColumbaApp
//
//  Compile-time runtime flavor and capabilities.
//

import Foundation

/// The one runtime architecture compiled for an app target.
///
/// `COLUMBA_RUNTIME_PYTHON` and `COLUMBA_RUNTIME_MODEL_B` are the canonical
/// flavor flags. Every app and test-host configuration must define exactly one;
/// persisted backend preferences have no role in this selection.
enum RuntimeFlavor: Equatable {
    case python
    case modelB

    static func resolve(persistedUseSwiftBackend: Bool?) -> RuntimeFlavor {
        // Deliberately ignored. Runtime architecture is a build property, not a
        // user preference; retaining the argument makes that boundary directly
        // testable against persisted values from older app versions.
        _ = persistedUseSwiftBackend

        #if COLUMBA_RUNTIME_PYTHON && COLUMBA_RUNTIME_MODEL_B
        #error("Exactly one Columba runtime flavor may be compiled")
        #elseif COLUMBA_RUNTIME_PYTHON
        return .python
        #elseif COLUMBA_RUNTIME_MODEL_B
        return .modelB
        #else
        #error("Exactly one Columba runtime flavor must be compiled")
        #endif
    }
}

/// Compile-time runtime flavor and capabilities.
///
/// The legacy persisted backend value is read only by `runtimeFlavor(defaults:)`
/// so tests can prove it cannot affect architecture selection. Runtime creation
/// uses exclusively the canonical `COLUMBA_RUNTIME_*` flags.
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
    /// compiled in on the Model B build (`COLUMBA_RUNTIME_MODEL_B` alongside the
    /// temporary `COLUMBA_BACKEND_SWIFT` and `ENABLE_NETWORK_EXTENSION` flags),
    /// and on that build Model B is the *sole* architecture — there is no toggle
    /// and no opt-out. On the shipping build the NE isn't present, so the app runs
    /// the foreground embedded-Python node.
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
}
