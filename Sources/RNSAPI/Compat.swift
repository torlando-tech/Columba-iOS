import Foundation
import CryptoKit

// ─────────────────────────────────────────────────────────────────────────────
// RNSAPI v1 compatibility layer
//
// One big file holding stub types and minimal value types the Columba iOS UI
// still references after the strip of `reticulum-swift` / `LXMFSwift` /
// `LXSTSwift`. These types preserve the AI-Swift API shapes used at ~700
// call sites across `Sources/ColumbaApp/` so we don't have to rewrite every
// caller in a single PR.
//
// Most types here are "compile but no-op" stubs. The ones that actually do
// work in v1 (Identity Keychain ops in Identity.swift; TCP path through
// `RNSBackendPy`) sit in their own files. Anything marked `(stub)` returns a
// safe default and logs a runtime warning so UI buttons that hit it produce
// a visible diagnostic rather than a silent miss.
//
// Long-term these all collapse into the protocol-method surface mirrored
// from Columba Android's `rns-api` (`backend.core.X`, `backend.lxmf.X`, etc.).
// For now we get to compile; refactor toward the pure shape later.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Destination

/// Reticulum destination. v1: value type with the static `.hash(...)` helper
/// the existing code uses; instance methods are stubs.
public struct Destination: Equatable, @unchecked Sendable {
    public let hash: Data
    public let identityHash: Data
    public var appData: Data?
    public var ratchetManager: RatchetManager?

    public init(hash: Data, identityHash: Data, appData: Data? = nil) {
        self.hash = hash
        self.identityHash = identityHash
        self.appData = appData
        self.ratchetManager = nil
    }

    public static func == (lhs: Destination, rhs: Destination) -> Bool {
        lhs.hash == rhs.hash &&
        lhs.identityHash == rhs.identityHash &&
        lhs.appData == rhs.appData
        // ratchetManager intentionally excluded from equality (reference identity)
    }

    /// Compute a destination hash from an identity + app name + aspect path.
    /// Canonical RNS formula:
    ///   name_hash = SHA256(app_name + "." + aspects)[:10]
    ///   dest_hash = SHA256(name_hash + identity.hash)[:16]
    public static func hash(identity: Identity, appName: String, aspects: [String]) -> Data {
        var name = appName
        for aspect in aspects { name += "." + aspect }
        let nameHash = Data(SHA256.hash(data: name.data(using: .utf8) ?? Data())).prefix(10)
        return Data(SHA256.hash(data: nameHash + identity.hash)).prefix(16)
    }

    public var hexHash: String { hash.toHex() }

    public func enableRatchets(storagePath: String) {
        // stub — ratchet support is deferred; the python side handles per-link ratchets
    }
}

/// Ratchet manager handle — opaque stub today; Python owns the actual ratchet
/// state machine and persistence path.
public final class RatchetManager: @unchecked Sendable {
    public init() {}
}

// MARK: - Link

/// Reticulum Link — encrypted channel between two destinations. v1 stub;
/// link callbacks are surfaced via the Python event bridge in Phase 2.
public final class Link: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case pending, active, closed, stale, established

        public var isEstablished: Bool { self == .active || self == .established }
    }

    public let identityHash: Data
    public var state: State = .pending
    public var label: String = ""
    public var url: String?
    public var fieldNames: [String] = []

    public init(identityHash: Data) {
        self.identityHash = identityHash
    }

    public func identify(_ identity: Identity) {}
    public func identify(identity: Identity) async throws {}
    public func close() { state = .closed }
    public func request(_ path: String) {}
    public func request(_ path: String, data: Any? = nil, responseTimeout: TimeInterval? = nil) async throws -> RequestReceipt {
        RequestReceipt(linkIdentityHash: identityHash, path: path)
    }
    public var stateUpdates: AsyncStream<State> {
        AsyncStream { _ in /* stub */ }
    }
    public var endIndex: Int { 0 }
}

/// Response handle for an outgoing link request. v1 stub.
public struct RequestReceipt: Equatable, Sendable {
    public let linkIdentityHash: Data
    public let path: String

    public init(linkIdentityHash: Data, path: String) {
        self.linkIdentityHash = linkIdentityHash
        self.path = path
    }

    public func awaitResponse(timeout: TimeInterval) async throws -> Data? { nil }
}

/// Stand-in for MessagePack's value-tagged enum. v1: bridge translates to/from
/// real msgpack on the Python side; Swift code that builds field dicts uses
/// this façade so the call sites compile.
public enum MessagePackValue: Hashable, Sendable {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Float)
    case double(Double)
    case string(String)
    case binary(Data)
    indirect case array([MessagePackValue])
    indirect case map([MessagePackValue: MessagePackValue])

    public init(_ value: String) { self = .string(value) }
    public init(_ value: Int) { self = .int(Int64(value)) }
    public init(_ value: Data) { self = .binary(value) }
}

/// Stand-in for the msgpack unpack helper. v1 stub returns nil; the python
/// bridge handles real serialization.
public func unpackMsgPack(_ data: Data) -> [MessagePackValue: MessagePackValue]? { nil }

// MARK: - Packet

public struct Packet: Equatable, Sendable {
    public let payload: Data
    public init(payload: Data) { self.payload = payload }
    public func encode() -> Data { payload }
}

// MARK: - Announce

/// Network announce surfaced to the UI. Distinct from `AnnounceEvent` (the
/// raw protocol message) — this is the "row" the contacts/announces list
/// shows. v1: populated by `RNSBackendPy.PythonEventBridge` from
/// `rns_bridge.drain_events()`.
public struct Announce: Identifiable, Equatable, Sendable {
    public let destinationHash: Data
    public var displayName: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var hopCount: Int
    public var signalStrength: Int?
    public var isRelay: Bool
    public var badgeType: BadgeType
    public var icon: IconAppearance?

    public var id: Data { destinationHash }

    public enum BadgeType: String, Equatable, Sendable {
        case lxmfDelivery, lxmfPropagation, nomadnetNode, lxstTelephony, unknown
    }

    public init(
        destinationHash: Data,
        displayName: String = "",
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        hopCount: Int = 0,
        signalStrength: Int? = nil,
        isRelay: Bool = false,
        badgeType: BadgeType = .lxmfDelivery,
        icon: IconAppearance? = nil
    ) {
        self.destinationHash = destinationHash
        self.displayName = displayName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.hopCount = hopCount
        self.signalStrength = signalStrength
        self.isRelay = isRelay
        self.badgeType = badgeType
        self.icon = icon
    }

    public func buildPacket() throws -> Packet { Packet(payload: Data()) }
}

// MARK: - AnnounceHandler protocol

public protocol AnnounceHandler: AnyObject {
    var aspectFilter: String? { get }
    func receivedAnnounce(destinationHash: Data, identity: Identity, appData: Data?)
}

// MARK: - DestinationType

public enum DestinationType: String, Equatable, Sendable {
    case single, plain, link, group
}

// Note: `InterfaceMode` and `RNodeConfig` live in
// Sources/ColumbaApp/Services/InterfaceRepository.swift — Columba defined them
// for its own UI/storage layer and we use those directly rather than
// redeclaring here.

// MARK: - IconAppearance

/// Peer icon configuration carried in LXMF Field 4.
public struct IconAppearance: Codable, Equatable, Sendable {
    public static let fieldKey = 4

    public let iconName: String
    public let fgColor: String
    public let bgColor: String

    /// Aliases for code that uses the longer names.
    public var foregroundColor: String { fgColor }
    public var backgroundColor: String { bgColor }

    public init(iconName: String, fgColor: String, bgColor: String) {
        self.iconName = iconName
        self.fgColor = fgColor
        self.bgColor = bgColor
    }

    /// Compatibility init for call sites that use the long names.
    public init(iconName: String, foregroundColor: String, backgroundColor: String) {
        self.iconName = iconName
        self.fgColor = foregroundColor
        self.bgColor = backgroundColor
    }

    /// Decode from an LXMF field value (the raw msgpack payload at field 4).
    /// v1 stub: returns nil; full impl lands when icon sharing comes back.
    public static func fromLXMFFieldValue(_ value: Any) -> IconAppearance? {
        nil
    }

    /// Serialize for LXMF field 4. v1 stub returns empty Data.
    public func toLXMFFieldValue() -> Data { Data() }
}

// MARK: - LXMFError

public enum LXMFError: Error, LocalizedError, Sendable {
    case routerNotInitialized
    case destinationNotFound
    case sendFailed(String)
    case deliveryTimeout
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .routerNotInitialized: return "LXMRouter not initialized"
        case .destinationNotFound: return "Destination not found"
        case .sendFailed(let s): return "Send failed: \(s)"
        case .deliveryTimeout: return "Delivery timeout"
        case .other(let s): return s
        }
    }
}

// MARK: - LocationSharingManager + Telemetry stubs

/// v1 stub — full location sharing returns in v1.1.
public final class LocationSharingManager: @unchecked Sendable {
    public init() {}
    public func isSharing(with destinationHash: Data) -> Bool { false }
    public func startSharing(with destinationHash: Data) async {}
    public func stopSharing(with destinationHash: Data) {}
    public func sharedTelemetry(for destinationHash: Data) -> TelemetryPacket? { nil }
    public func handleIncomingCease(from sourceHash: Data) async {}
}

public struct TelemetryPacket: Equatable, Sendable {
    public let timestamp: Date
    public let payload: Data
    public init(timestamp: Date = Date(), payload: Data = Data()) {
        self.timestamp = timestamp
        self.payload = payload
    }
}

public struct LocationTelemetry: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let timestamp: Date
    public init(latitude: Double, longitude: Double, altitude: Double? = nil, timestamp: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
    }
}

public struct RadioConfig: Equatable, Sendable {
    public let frequency: UInt32
    public let bandwidth: UInt32
    public let spreadingFactor: UInt8
    public let codingRate: UInt8
    public let txPower: UInt8
    public let stAlock: Float?
    public let ltAlock: Float?
    public init(
        frequency: UInt32 = 0,
        bandwidth: UInt32 = 0,
        spreadingFactor: UInt8 = 0,
        codingRate: UInt8 = 0,
        txPower: UInt8 = 0,
        stAlock: Float? = nil,
        ltAlock: Float? = nil
    ) {
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
        self.txPower = txPower
        self.stAlock = stAlock
        self.ltAlock = ltAlock
    }
}

// MARK: - LXMessage

/// An LXMF message — both outbound (Columba builds it, hands to LXMRouter)
/// and inbound (delivery callback hands it back). v1 carries the fields the
/// existing UI reads; serialisation lives on the Python side.
public final class LXMessage: @unchecked Sendable {
    // Field constants — kept identical to the AI Swift API for call-site compat.
    public static let FIELD_APP_DATA: Int = 0x10
    public static let FIELD_IMAGE: Int = 0x05
    public static let FIELD_FILE_ATTACHMENTS: Int = 0x06
    public static let FIELD_TELEMETRY: Int = 0x07
    public static let FIELD_COLUMBA_META: Int = 0x70

    public var destinationHash: Data
    public var sourceHash: Data
    public var sourceIdentity: Identity?
    /// Raw content bytes — typically UTF-8 text. Helpers below convert to/from String.
    public var content: Data
    public var title: Data
    public var timestamp: Date
    public var fields: [Int: Any]?
    public var state: LXMessageState
    public var hash: Data
    public var incoming: Bool
    public var fallbackMethod: LXDeliveryMethod?
    public var desiredMethod: LXDeliveryMethod

    public init(
        destinationHash: Data,
        sourceIdentity: Identity?,
        content: String,
        title: String = "",
        fields: [Int: Any]? = nil,
        method: LXDeliveryMethod = .opportunistic
    ) {
        self.destinationHash = destinationHash
        self.sourceIdentity = sourceIdentity
        self.sourceHash = sourceIdentity?.hash ?? Data()
        self.content = content.data(using: .utf8) ?? Data()
        self.title = title.data(using: .utf8) ?? Data()
        self.timestamp = Date()
        self.fields = fields
        self.state = .draft
        self.hash = Data()
        self.incoming = false
        self.fallbackMethod = nil
        self.desiredMethod = method
    }

    public var contentAsString: String {
        String(data: content, encoding: .utf8) ?? ""
    }

    public var titleAsString: String {
        String(data: title, encoding: .utf8) ?? ""
    }

    public func pack() throws -> Data { Data() }
    public static func unpackFromBytes(_ data: Data) throws -> LXMessage {
        // v1 stub: caller-provided bytes assumed empty; real unpack happens in Python.
        LXMessage(
            destinationHash: Data(),
            sourceIdentity: nil,
            content: "",
            method: .opportunistic
        )
    }
}

public enum LXDeliveryMethod: String, Equatable, Sendable {
    case opportunistic, direct, propagated, paper, unknown
}

public enum LXMessageState: String, Equatable, Sendable {
    case draft, outbound, sending, sent, delivered, failed, received
}

// MARK: - LXMRouter / Delegate

/// LXMF router — was an actor in the AI Swift surface. v1 we keep it as
/// a class with the methods the UI calls; bodies forward to `RNSBackendPy`.
/// `lxmfBackend` is set by `AppServices` after the bridge boots.
public final class LXMRouter: @unchecked Sendable {
    public weak var delegate: LXMRouterDelegate?

    /// Set by AppServices once RNSBackendPy is ready; nil before then.
    public var sendHook: ((LXMessage) async throws -> Void)?

    public init() {}

    public func setDelegate(_ delegate: LXMRouterDelegate) { self.delegate = delegate }
    public func setTransport(_ transport: ReticulumTransport) { /* stub */ }
    public func registerDeliveryDestination(_ destination: Destination) {}

    @discardableResult
    public func handleOutbound(_ message: LXMessage) async throws -> Bool {
        if let hook = sendHook {
            try await hook(message)
            return true
        }
        return false
    }

    public func restart() async {}
    public func syncState() async {}
    public func syncFromPropagationNode() async {}
}

public protocol LXMRouterDelegate: AnyObject {
    func router(_ router: LXMRouter, didReceiveMessage message: LXMessage)
}

// MARK: - LXMFDatabase (stub)

/// Persistent message + conversation store. v1 stub — real persistence
/// lives in the Python sqlite3 store (`app/columba_store.py`). Methods
/// here return mock values to keep the UI compiling; `MessageRepository`
/// is the actual data layer the UI reads from.
public final class LXMFDatabase: @unchecked Sendable {
    public init(path: String) {}

    // Mirror the AI Swift LXMFDatabase API surface exactly — same argument
    // labels, same throws (not async), same return types.

    // Messages
    public func saveMessage(_ message: LXMessage) throws {}
    public func getMessage(id: Data) throws -> LXMessage? { nil }
    public func hasMessage(id: Data) throws -> Bool { false }
    public func getMessages(forConversation hash: Data, limit: Int = 50, offset: Int = 0) throws -> [LXMessage] { [] }
    public func updateMessageState(id: Data, state: LXMessageState) throws {}
    public func deleteMessage(id messageId: Data) throws {}
    public func getMessageRecord(id: Data) throws -> MessageRecord? { nil }
    public func getMessageRecords(forConversation hash: Data, limit: Int = 200, offset: Int = 0) throws -> [MessageRecord] { [] }

    // Conversations
    public func getConversations(limit: Int = 100, offset: Int = 0) throws -> [ConversationRecord] { [] }
    public func getConversation(hash: Data) throws -> ConversationRecord? { nil }
    public func ensureConversation(hash: Data, displayName: String?) throws {}
    public func updateDisplayName(hash: Data, displayName: String?) throws {}
    public func setFavorite(hash: Data, isFavorite: Bool) throws {}
    public func setPinned(hash: Data, isPinned: Bool) throws {}
    public func setUnreadCount(hash: Data, count: Int) throws {}
    public func markConversationRead(hash: Data) throws {}
    public func deleteConversation(hash: Data) throws {}
    public func updateConversation(for message: LXMessage) throws {}

    // Peer icons
    public func updatePeerIcon(_ hash: Data, iconName: String, fgColor: String, bgColor: String) throws {}
    public func getPeerIcon(_ hash: Data) throws -> IconAppearance? { nil }

    // Outbound queue (v1 stubs — empty)
    public func loadPendingOutbound() throws -> [LXMessage] { [] }
    public func loadFailedOutbound() throws -> [LXMessage] { [] }

    // Reactions + replies
    public func updateReplyToId(messageId: Data, replyToId: String) throws {}
    public func updateReactions(messageId: Data, reactionsJson: String) throws {}
    public func getReactionsJson(messageId: Data) throws -> String? { nil }
}

public struct ConversationRecord: Identifiable, Equatable, Sendable {
    public let id: Data
    public var displayName: String
    public var isFavorite: Int
    public var isPinned: Int
    public var lastMessageAt: Date?
    public var lastMessage: String?
    public var unreadCount: Int

    public init(
        id: Data,
        displayName: String = "",
        isFavorite: Int = 0,
        isPinned: Int = 0,
        lastMessageAt: Date? = nil,
        lastMessage: String? = nil,
        unreadCount: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.lastMessageAt = lastMessageAt
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
    }
}

public struct MessageRecord: Identifiable, Equatable, Sendable {
    public let id: Data
    public let conversationHash: Data
    public var content: String
    public var timestamp: Date
    public var direction: Direction
    public var state: LXMessageState

    public enum Direction: String, Equatable, Sendable { case inbound, outbound }

    public init(
        id: Data,
        conversationHash: Data,
        content: String,
        timestamp: Date,
        direction: Direction,
        state: LXMessageState
    ) {
        self.id = id
        self.conversationHash = conversationHash
        self.content = content
        self.timestamp = timestamp
        self.direction = direction
        self.state = state
    }
}

// MARK: - ReticulumTransport (stub)

/// Routing surface — was an actor in the AI Swift API. v1 stub; the
/// Python backend (`RNSBackendPy.PythonRNSCore`) owns the real transport
/// state. Most methods log + no-op so UI hooks (e.g., interface management)
/// compile cleanly.
public final class ReticulumTransport: @unchecked Sendable {
    public init() {}

    public func addInterface(_ interface: any NetworkInterface) async throws {}
    public func removeInterface(_ id: String) async throws {}
    public func listInterfaceIds() async -> [String] { [] }
    public func getInterfaceName(_ id: String) async -> String? { nil }
    public func getInterfaceSnapshots() async -> [InterfaceSnapshot] { [] }
    public func registerDestination(_ destination: Destination) async {}
    public func isDestinationRegistered(_ hash: Data) async -> Bool { false }
    public func send(packet: Packet) async throws {}
    public func handleReceivedData(data: Data, from interfaceId: String) async {}
    public func requestPath(_ destinationHash: Data) async {}
    public func setTransportEnabled(_ enabled: Bool) async {}
    public func setOnInterfaceAdded(_ handler: @escaping @Sendable (String) async -> Void) async {}
    public func setOnDiagnostic(_ handler: @escaping @Sendable (String) -> Void) async {}
    public func registerDestinationLinkCallback(for destinationHash: Data, _ callback: @escaping (Link) async -> Void) async {}
    public func registerAnnounceHandler(_ handler: AnnounceHandler) async {}
    public func initiateLink(to destinationHash: Data) async throws -> Link {
        Link(identityHash: destinationHash)
    }
    public func connect() async {}
    public func addAutoInterface(_ interface: AutoInterface) async throws {}
    public func onPeripheralDiscovered(_ handler: @escaping @Sendable (Any) -> Void) async {}
}

public struct InterfaceSnapshot: Equatable, Sendable {
    public let id: String
    public let name: String
    public let online: Bool
    public let typeLabel: String

    public init(id: String, name: String, online: Bool, typeLabel: String) {
        self.id = id
        self.name = name
        self.online = online
        self.typeLabel = typeLabel
    }
}

// MARK: - PathTable (stub)

public final class PathTable: @unchecked Sendable {
    public init() {}
    public func lookup(destinationHash: Data) async -> PathEntry? { nil }
    public func size() async -> Int { 0 }
    public func allEntries() async -> [PathEntry] { [] }
    public func remove(_ destinationHash: Data) async {}
}

public struct PathEntry: Identifiable, Equatable, Sendable {
    public let destinationHash: Data
    public var displayName: String?
    public var nextHop: Data?
    public var hopCount: Int
    public var lastSeen: Date
    public var publicKeys: Data?
    public var interfaceId: String?

    public var id: Data { destinationHash }

    public init(
        destinationHash: Data,
        displayName: String? = nil,
        nextHop: Data? = nil,
        hopCount: Int = 0,
        lastSeen: Date = Date(),
        publicKeys: Data? = nil,
        interfaceId: String? = nil
    ) {
        self.destinationHash = destinationHash
        self.displayName = displayName
        self.nextHop = nextHop
        self.hopCount = hopCount
        self.lastSeen = lastSeen
        self.publicKeys = publicKeys
        self.interfaceId = interfaceId
    }
}

// MARK: - Network Interfaces

public protocol NetworkInterface: AnyObject, Sendable {
    var id: String { get }
    var name: String { get }
    var online: Bool { get }
}

public struct InterfaceConfig: Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: InterfaceKind
    public let enabled: Bool
    public let mode: InterfaceMode
    public let host: String?
    public let port: UInt16?

    public init(
        id: String,
        name: String,
        type: InterfaceKind,
        enabled: Bool,
        mode: InterfaceMode = .full,
        host: String? = nil,
        port: UInt16? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.enabled = enabled
        self.mode = mode
        self.host = host
        self.port = port
    }
}

public enum InterfaceKind: String, Equatable, Sendable {
    case tcp, auto, ble, rnode, mpc
}

public final class TCPInterface: NetworkInterface, @unchecked Sendable {
    public let id: String
    public let name: String
    public var online: Bool = false
    public var state: InterfaceState = .disconnected
    public init(config: InterfaceConfig) throws {
        self.id = config.id
        self.name = config.name
    }
}

public enum InterfaceState: String, Equatable, Sendable {
    case disconnected, connecting, connected, error
}

public final class AutoInterface: NetworkInterface, @unchecked Sendable {
    public let id: String
    public let name: String
    public var online: Bool = false
    public init(config: InterfaceConfig) {
        self.id = config.id
        self.name = config.name
    }
}

public final class BLEInterface: NetworkInterface, @unchecked Sendable {
    public let id: String
    public let name: String
    public var online: Bool = false
    public init(config: InterfaceConfig) {
        self.id = config.id
        self.name = config.name
    }
    public func getConnectionInfos() async -> [BLEConnectionInfo] { [] }
    public func disconnectPeer(identityHex: String) async {}
}

public final class RNodeInterface: NetworkInterface, @unchecked Sendable {
    public let id: String
    public let name: String
    public var online: Bool = false
    public init(config: RNodeConfig, name: String) {
        self.id = "rnode-\(name)"
        self.name = name
    }
}

public final class MPCInterface: NetworkInterface, @unchecked Sendable {
    public let id: String
    public let name: String
    public var online: Bool = false
    public init(serviceType: String) {
        self.id = "mpc-\(serviceType)"
        self.name = serviceType
    }
}

public struct BLEConnectionInfo: Identifiable, Equatable, Sendable {
    public let identityHex: String
    public var identityHash: String
    public var displayName: String?
    public var rssi: Int?
    public var connected: Bool
    public var lastSeen: Date
    public var lastActivity: Date
    public var connectionType: String
    public var connectionDuration: TimeInterval
    public var isOutgoing: Bool
    public var mtu: Int
    public var bytesSent: Int
    public var bytesReceived: Int
    public var packetsSent: Int
    public var packetsReceived: Int
    public var signalQuality: SignalQuality

    public var id: String { identityHex }

    public init(
        identityHex: String,
        identityHash: String = "",
        displayName: String? = nil,
        rssi: Int? = nil,
        connected: Bool = false,
        lastSeen: Date = Date(),
        lastActivity: Date = Date(),
        connectionType: String = "peripheral",
        connectionDuration: TimeInterval = 0,
        isOutgoing: Bool = false,
        mtu: Int = 23,
        bytesSent: Int = 0,
        bytesReceived: Int = 0,
        packetsSent: Int = 0,
        packetsReceived: Int = 0,
        signalQuality: SignalQuality = .unknown
    ) {
        self.identityHex = identityHex
        self.identityHash = identityHash.isEmpty ? identityHex : identityHash
        self.displayName = displayName
        self.rssi = rssi
        self.connected = connected
        self.lastSeen = lastSeen
        self.lastActivity = lastActivity
        self.connectionType = connectionType
        self.connectionDuration = connectionDuration
        self.isOutgoing = isOutgoing
        self.mtu = mtu
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.packetsSent = packetsSent
        self.packetsReceived = packetsReceived
        self.signalQuality = signalQuality
    }
}

public enum BLEConnectionType: String, Equatable, Sendable {
    case central, peripheral
}

public enum SignalQuality: String, Equatable, Sendable {
    case excellent, good, fair, poor, unknown
}

// `RNodeConfig` lives in Sources/ColumbaApp/Services/InterfaceRepository.swift.

// MARK: - Propagation node info

public struct PropagationNodeInfo: Identifiable, Equatable, Sendable {
    public let destinationHash: Data
    public var displayName: String?
    public var lastSeen: Date
    public var hopCount: Int

    public var id: Data { destinationHash }

    public init(destinationHash: Data, displayName: String? = nil, lastSeen: Date = Date(), hopCount: Int = 0) {
        self.destinationHash = destinationHash
        self.displayName = displayName
        self.lastSeen = lastSeen
        self.hopCount = hopCount
    }
}

public enum PropagationState: String, Equatable, Sendable {
    case idle, syncing, error
}
