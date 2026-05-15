import Foundation

/// An `lxmf.delivery` announce surfaced from Python RNS to Swift.
///
/// Produced by `PythonBridge.Event.announce` after `rns_bridge._LXMFAnnounceHandler`
/// receives one from the Python-side `RNS.Transport`. The original `app_data` from
/// the announce packet has already been msgpack-decoded to `displayName`.
///
/// Named `PyAnnounce` (not `Announce`) so it doesn't collide with the old
/// `ReticulumSwift.Announce` type during the Phase 1 transition.
public struct PyAnnounce: Identifiable, Equatable, Sendable {
    public let destHash: String
    public var displayName: String
    public var firstSeen: Date
    public var lastSeen: Date

    public var id: String { destHash }

    public init(destHash: String, displayName: String, firstSeen: Date, lastSeen: Date) {
        self.destHash = destHash
        self.displayName = displayName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}
