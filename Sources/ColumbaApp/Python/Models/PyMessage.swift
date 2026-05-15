import Foundation

/// An LXMF message surfaced from / submitted to the Python bridge.
///
/// Wire-form invariant: when an inbound `LXMessage` lands in Python, `rns_bridge`'s
/// `_delivery_callback` reads `.source_hash`, `.content_as_string()`,
/// `.title_as_string()`, and the receipt timestamp, then emits
/// `PythonBridge.Event.inbound`. The bridge marshals that dict into this struct.
///
/// Named `PyMessage` (not `Message`) to avoid colliding with the existing
/// `LXMFSwift.Message` during the Phase 1 transition; the existing
/// `MessageRepository` still hands out `LXMFSwift.Message` until the AppServices
/// rewrite lands.
public struct PyMessage: Identifiable, Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case inbound, outbound }

    public enum DeliveryMethod: Equatable, Sendable {
        case opportunistic
        case direct
        case propagated
        case unknown
    }

    public let id: UUID
    public let peerHash: String
    public let direction: Direction
    public let content: String
    public let title: String
    public let timestamp: Date
    public var method: DeliveryMethod

    public init(
        id: UUID = UUID(),
        peerHash: String,
        direction: Direction,
        content: String,
        title: String = "",
        timestamp: Date,
        method: DeliveryMethod = .unknown
    ) {
        self.id = id
        self.peerHash = peerHash
        self.direction = direction
        self.content = content
        self.title = title
        self.timestamp = timestamp
        self.method = method
    }
}
