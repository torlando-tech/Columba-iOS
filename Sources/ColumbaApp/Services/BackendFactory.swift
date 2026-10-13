import Foundation
import RNSAPI

/// Only the transport varies. All UI mapping, inbox replay, field encoding,
/// outbox admission, and node commands are identical in both hosting modes.
@available(iOS 17.0, macOS 14.0, *)
enum BackendFactory {
    static func make(mode: NodeHostingMode, proxySend: @escaping @Sendable (Data) async -> Data?) -> any RnsBackend {
        switch mode {
        case .networkExtension:
            return ProxyRnsBackend(send: proxySend)
        case .foreground:
            let local = LocalNodeAdapter()
            return ProxyRnsBackend(send: { await local.send($0) })
        }
    }
}
