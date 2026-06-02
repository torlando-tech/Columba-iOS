//
//  BackendPreference.swift
//  ColumbaApp
//
//  Runtime selection of the active RNS backend.
//

import Foundation

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
    private static let modelBKey = "modelBBackgroundNE"

    /// Model B master flag (Tracks A5b/C3). When `true`, `BackendFactory.make()`
    /// returns the thin-client `ProxyRnsBackend` (which owns no destination and
    /// marshals node-owning ops to the in-NE `NEReticulumNode` over IPC) instead
    /// of a destination-owning backend, AND the NE activates its in-extension node
    /// as the live delivery path. **Default `false`** — current PoC behavior is
    /// unchanged; Model B is opt-in (the user flips this to device-test). Stored in
    /// the App Group suite so it survives relaunch and is visible to the NE, like
    /// `useSwiftBackend`.
    ///
    /// UNIFIED SWITCH (C3): this is the SAME App-Group key
    /// (`modelBBackgroundNE`) the NE reads via `NEReticulumNode.modelBNodeEnabled`,
    /// so the app-side backend selection and the NE-side node activation share ONE
    /// flag — flipping it here flips both.
    ///
    /// INVARIANT: this is mutually exclusive with running a local
    /// `Swift`/`Python` backend — when it's on, the NE is the SINGLE owner of the
    /// `lxmf.delivery` destination (see `BackendFactory.make()` and
    /// `ProxyRnsBackend`'s always-the-node note).
    static var modelB: Bool {
        get {
            guard let stored = SharedDefaults.suite.object(forKey: modelBKey) as? Bool else {
                return false
            }
            return stored
        }
        set { SharedDefaults.suite.set(newValue, forKey: modelBKey) }
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
