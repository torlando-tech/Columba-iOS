import Foundation
import RNSAPI

/// Constructs the active RNS backend. **Build-time selected** — the embedded
/// Python backend today; the `#if COLUMBA_BACKEND_SWIFT` branch (the native
/// reticulum-swift/LXMF-swift `SwiftRNSBackend`) is wired in Phase 2. The rest
/// of the app depends only on `any RnsBackend`, so swapping backends never
/// touches the UI or `AppServices`.
@available(iOS 17.0, macOS 14.0, *)
enum BackendFactory {
    static func make() -> any RnsBackend {
        #if COLUMBA_BACKEND_SWIFT
        return SwiftRNSBackend()
        #else
        return PythonRNSBackend()
        #endif
    }
}
