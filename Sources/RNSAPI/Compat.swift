import Foundation
import CryptoKit

// ─────────────────────────────────────────────────────────────────────────────
// RNSAPI v1 compatibility layer — types that mirror the public API surface
// of the deleted AI-Swift libraries (reticulum-swift / LXMF-swift / LXSTSwift)
// so the existing Columba iOS UI compiles unchanged on top of the new
// Python-backed protocol layer.
//
// Real behavior wired in:
//   * Identity (separate file): Keychain + CryptoKit key derivation
//   * Destination.hash(...) helpers (SHA-256 truncation, matches RNS wire)
//
// Stubbed (compile-only, body returns nil/empty/false or no-ops):
//   * Most interface lifecycle methods (connect/disconnect/send/etc.)
//   * RatchetManager
//   * Callback registration (callback manager not wired)
//   * Crypto methods (sign/verify/encrypt/decrypt — Python does the work)
//   * Database persistence (Python sqlite3 store is the truth)
//
// Each stub is small enough that a runtime call no-ops rather than crashes.
// Buttons that hit stubbed paths will appear to do nothing — by design for
// v1; the bridge wiring for each lands in RNSBackendPy as feature areas
// come back online (BLE, AutoInterface, etc.).
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Hash helpers

public enum Hashing {
    /// 10-byte truncated SHA-256 of the dotted destination name.
    public static func destinationNameHash(appName: String, aspects: [String]) -> Data {
        var name = appName
        for aspect in aspects { name += "." + aspect }
        return Data(SHA256.hash(data: name.data(using: .utf8) ?? Data())).prefix(10)
    }

    /// 16-byte truncated SHA-256 (canonical RNS truncation).
    public static func truncatedHash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data)).prefix(16)
    }

    /// 16-byte identity hash from concatenated 32+32 public keys.
    public static func identityHash(encryptionPublicKey: Data, signingPublicKey: Data) -> Data {
        Data(SHA256.hash(data: encryptionPublicKey + signingPublicKey)).prefix(16)
    }
}

// MARK: - Enums

public enum DestType: UInt8, Sendable {
    case single = 0x00
    case group  = 0x01
    case plain  = 0x02
    case link   = 0x03
}

public enum DestinationType: String, Equatable, Sendable {
    case single, plain, link, group
}

public enum DestinationDirection: Sendable {
    case `in`
    case out
}

// Note: Columba defines its own `InterfaceType` in
// Sources/ColumbaApp/Services/InterfaceRepository.swift with UI-layer cases
// (tcpClient, tcpServer, multipeer, ...). The protocol-layer
// `InterfaceConfig.type` below uses a separate enum (`WireInterfaceType`)
// keyed to the wire-side names AppServices already passes (`.tcp`, `.ble`,
// `.autoInterface`, `.rnode`, `.multipeerConnectivity`).
public enum WireInterfaceType: String, Sendable, Equatable {
    case tcp
    case udp
    case i2p
    case autoInterface
    case rnode
    case ble
    case multipeerConnectivity
}

public enum InterfaceState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int = 0)
    case connectionFailed(underlying: String)
    case sendFailed(underlying: String)
    case notConnected
    case invalidConfig(reason: String)
}

public enum LXDeliveryMethod: String, Equatable, Sendable {
    case opportunistic, direct, propagated, paper, unknown
}

public enum LXMessageState: String, Equatable, Sendable, Codable {
    case draft, outbound, sending, sent, delivered, failed, received
}

public enum LXMessageRepresentation: String, Equatable, Sendable {
    case unknown, opportunistic, direct, propagated
}

public enum LXUnverifiedReason: String, Equatable, Sendable {
    case signatureMismatch, missingIdentity, malformed
}

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

// MARK: - Destination

/// Reticulum destination. Mirrors the AI-Swift `Destination` class so the
/// existing Columba UI compiles unchanged. Hash computation uses real SHA-256
/// truncation (matches RNS wire format). Callbacks / ratchets / streams are
/// stub no-ops — those wire through `RNSBackendPy` in later commits.
public final class Destination: @unchecked Sendable {
    public let identity: Identity?
    public let appName: String
    public let aspects: [String]
    public let destinationType: DestType
    public var direction: DestinationDirection
    public var appData: Data?
    public var ratchetManager: RatchetManager?
    public private(set) var ratchetsEnabled: Bool = false
    public private(set) var ratchetsEnforced: Bool = false

    public var hash: Data {
        switch destinationType {
        case .single, .link:
            guard let identity else { return Destination.plainHash(appName: appName, aspects: aspects) }
            return Destination.hash(identity: identity, appName: appName, aspects: aspects)
        case .plain, .group:
            return Destination.plainHash(appName: appName, aspects: aspects)
        }
    }

    public var publicKeys: Data? { identity?.publicKeys }
    public var nameHash: Data { Hashing.destinationNameHash(appName: appName, aspects: aspects) }
    public var fullName: String { aspects.isEmpty ? appName : appName + "." + aspects.joined(separator: ".") }
    public var announceNameHash: Data { nameHash }
    public var hexHash: String { hash.toHex() }

    public init(
        identity: Identity,
        appName: String,
        aspects: [String] = [],
        type: DestType = .single,
        direction: DestinationDirection = .in
    ) {
        self.identity = identity
        self.appName = appName
        self.aspects = aspects
        self.destinationType = type
        self.direction = direction
    }

    public init(
        plainAppName appName: String,
        aspects: [String] = [],
        direction: DestinationDirection = .in
    ) {
        self.identity = nil
        self.appName = appName
        self.aspects = aspects
        self.destinationType = .plain
        self.direction = direction
    }

    public func setCallbackManager(_ manager: Any) {}

    public func registerCallback(_ callback: @escaping (Data, Packet) -> Void) throws {}

    public func createPacketStream() -> AsyncStream<(Data, Packet)>? { nil }

    public func enableRatchets(storagePath: String) async throws {
        ratchetsEnabled = true
        ratchetManager = RatchetManager()
    }

    public func enforceRatchets() { ratchetsEnforced = ratchetsEnabled }

    public static func hash(identity: Identity, appName: String, aspects: [String] = []) -> Data {
        var combined = Hashing.destinationNameHash(appName: appName, aspects: aspects)
        combined.append(identity.hash)
        return Hashing.truncatedHash(combined)
    }

    public static func plainHash(appName: String, aspects: [String] = []) -> Data {
        Hashing.truncatedHash(Hashing.destinationNameHash(appName: appName, aspects: aspects))
    }

    public static func hash(
        encryptionPublicKey: Data,
        signingPublicKey: Data,
        appName: String,
        aspects: [String] = []
    ) -> Data {
        let idHash = Hashing.identityHash(encryptionPublicKey: encryptionPublicKey, signingPublicKey: signingPublicKey)
        var combined = Hashing.destinationNameHash(appName: appName, aspects: aspects)
        combined.append(idHash)
        return Hashing.truncatedHash(combined)
    }
}

extension Destination: CustomStringConvertible {
    public var description: String { "Destination<\(fullName):\(hexHash.prefix(8))...>" }
}

public enum DestinationError: Error, Sendable {
    case identityRequired
    case plainCannotAnnounce
    case invalidAppName
    case callbackManagerNotSet
}

public final class RatchetManager: @unchecked Sendable {
    public init() {}
    public init(storagePath: String, identity: Identity) {}
    public func loadOrCreate() async throws {}
    public func rotateIfNeeded() async {}
    /// Called both as a property and as a method in different sites — provide both.
    public func currentRatchetPublicBytes() async -> Data? { nil }
}

// MARK: - Packet / Announce / Link

public struct Packet: Equatable, Sendable {
    public let payload: Data
    public init(payload: Data = Data()) { self.payload = payload }
    public func encode() -> Data { payload }
}

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

    public init(destination: Destination, ratchet: Data? = nil) {
        self.destinationHash = destination.hash
        self.displayName = ""
        self.firstSeen = Date()
        self.lastSeen = Date()
        self.hopCount = 0
        self.signalStrength = nil
        self.isRelay = false
        self.badgeType = .lxmfDelivery
        self.icon = nil
    }

    public func buildPacket() throws -> Packet { Packet() }
}

public protocol AnnounceHandler: AnyObject {
    var aspectFilter: String? { get }
    func receivedAnnounce(destinationHash: Data, identity: Identity, appData: Data?)
}

/// Reason a Link was torn down. Mirrors the reticulum-swift teardown reasons
/// and the Python `RNS.Link.closed_callback` reason argument
/// (0 = link timeout, 1 = initiator closed, 2 = destination closed, 3 = network failure).
public enum TeardownReason: String, Equatable, Sendable {
    case timeout
    case initiatorClosed
    case destinationClosed
    case networkFailure
}

/// Protocol for Link identification callbacks — fires when the remote peer
/// sends a `LINK_IDENTIFY` packet revealing their identity. Mirrors the
/// reticulum-swift `IdentifyCallbacks` surface lxst-swift's Telephone uses.
public protocol IdentifyCallbacks: AnyObject, Sendable {
    func remoteIdentified(_ identity: Identity) async
}

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
    public var endIndex: Int { 0 }

    /// Bridge-allocated Link ID. Set by AppServices when wrapping a Python
    /// link_state event into a Compat Link instance; zero on Links that
    /// never crossed the bridge (e.g., the stub from `initiateLink`).
    public var linkId: UInt64 = 0

    /// Hook installed by AppServices that forwards bytes to the Python
    /// RNS.Link via `PythonRNSBackend.linkSend(linkId:data:)`. Set once
    /// the Link is wired; nil until then.
    public var sendBytesHook: (@Sendable (Data) async throws -> Void)?

    /// Hook installed by AppServices that forwards a LINKIDENTIFY request
    /// to the Python RNS.Link via `PythonRNSBackend.linkIdentify(linkId:)`.
    /// Telephone calls Link.identify(identity:) after receiving AVAILABLE
    /// on an outbound call; that has to translate into the Python-side
    /// `link.identify(identity)` call so the remote peer learns our
    /// identity and can apply its caller-allowed filter.
    public var identifyHook: (@Sendable () async throws -> Void)?

    /// Hooks installed by lxst-swift via `setCloseCallback` /
    /// `setIdentifyCallbacks` — invoked by AppServices when the corresponding
    /// Python events fire (link_state(closed) → closeCallback;
    /// link_identified → identifyCallbacks.remoteIdentified).
    public var closeCallback: (@Sendable (TeardownReason) async -> Void)?
    /// Strong reference to the identify handler. lxst-swift's Telephone
    /// creates a `TelephoneIdentifyHandler` inline and hands it off here
    /// with no caller-held reference; if this was weak the handler would
    /// deallocate before Python's link_identified event arrived and the
    /// inbound-call flow would silently stall at AVAILABLE.
    public var identifyCallbacks: (any IdentifyCallbacks)?

    /// Fired when the link finishes establishing. AppServices invokes this
    /// when Python emits link_state(state=established) for this linkId.
    public var establishedCallback: (@Sendable (Link) async -> Void)?

    /// Packet callback for inbound data on the Link. Installed by lxst-swift
    /// (LinkSource); fired by AppServices when a Python link_packet event
    /// arrives for this linkId. Carries the decrypted bytes from the remote.
    public var packetCallback: (@Sendable (Data, Packet) async -> Void)?

    public init(identityHash: Data) { self.identityHash = identityHash }

    public func identify(_ identity: Identity) {
        // Synchronous form — fire-and-forget through the async hook.
        if let hook = identifyHook {
            Task { try? await hook() }
        }
    }
    public func identify(identity: Identity) async throws {
        if let hook = identifyHook {
            try await hook()
        }
    }
    public func close() { state = .closed }
    public func request(_ path: String) {}
    public func request(_ path: String, data: Any? = nil, responseTimeout: TimeInterval? = nil) async throws -> RequestReceipt {
        RequestReceipt(linkIdentityHash: identityHash, path: path)
    }
    public var stateUpdates: AsyncStream<State> { AsyncStream { _ in } }

    /// Pass-through for Compat-layer Links — the Python `RNS.Link`
    /// transparently encrypts every Packet payload when the Packet is built,
    /// so callers like lxst-swift's Packetizer that historically called
    /// `link.encrypt(_:)` before handing bytes to the transport just get the
    /// data back unchanged on iOS.
    public func encrypt(_ data: Data) async throws -> Data { data }

    /// Pass-through to mirror `encrypt(_:)` for symmetry. The Python side
    /// also decrypts inbound link Packet payloads transparently before the
    /// `link_packet` event is emitted, so the bytes lxst-swift receives are
    /// already plaintext.
    public func decrypt(_ data: Data) async throws -> Data { data }

    /// Send bytes over the link. Forwards to `sendBytesHook` when wired;
    /// silently drops on unwired Links (e.g., the stub from `initiateLink`).
    public func sendBytes(_ data: Data) async throws {
        if let hook = sendBytesHook { try await hook(data) }
    }

    /// Install the close-reason callback (lxst-swift Telephone uses this).
    /// Accepts nil so the caller can clear the callback before closing the
    /// link to suppress a spurious "remote closed" delivery during local
    /// hangup.
    public func setCloseCallback(_ callback: (@Sendable (TeardownReason) async -> Void)?) async {
        self.closeCallback = callback
    }

    /// Install the identify-callbacks bridge. Accepts nil to clear.
    public func setIdentifyCallbacks(_ callbacks: (any IdentifyCallbacks)?) async {
        self.identifyCallbacks = callbacks
    }

    /// Install the packet callback. lxst-swift's LinkSource calls this after
    /// constructing itself; AppServices forwards Python link_packet events
    /// here.
    public func setPacketCallback(_ callback: @escaping @Sendable (Data, Packet) async -> Void) async {
        self.packetCallback = callback
    }

    /// Install the established callback — fires once the Python side reports
    /// link_state(state=established) for this linkId. CallManager uses this
    /// to defer "send AVAILABLE" until after the LRRTT handshake completes
    /// (sending earlier would race the encryption-key setup).
    public func setLinkEstablishedCallback(_ callback: @escaping @Sendable (Link) async -> Void) async {
        self.establishedCallback = callback
    }
}

public struct RequestReceipt: Equatable, Sendable {
    public let linkIdentityHash: Data
    public let path: String
    public init(linkIdentityHash: Data, path: String) {
        self.linkIdentityHash = linkIdentityHash
        self.path = path
    }
    public var statusUpdates: AsyncStream<String> { AsyncStream { _ in } }
    public func awaitResponse(timeout: TimeInterval) async throws -> Data? { nil }
}

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
}

// `packMsgPack` / `unpackMsgPack` live in RNSAPI/Util/MsgPack.swift — real
// implementation supporting the wire-format subset LXST uses.

// MARK: - IconAppearance

public struct IconAppearance: Codable, Equatable, Sendable {
    public static let fieldKey: UInt8 = 0x04

    public let iconName: String
    public let fgColor: String
    public let bgColor: String

    public var foregroundColor: String { fgColor }
    public var backgroundColor: String { bgColor }

    public init(iconName: String, fgColor: String, bgColor: String) {
        self.iconName = iconName; self.fgColor = fgColor; self.bgColor = bgColor
    }

    public init(iconName: String, foregroundColor: String, backgroundColor: String) {
        self.iconName = iconName; self.fgColor = foregroundColor; self.bgColor = backgroundColor
    }

    public static func fromLXMFFieldValue(_ value: Any) -> IconAppearance? { nil }
    public func toLXMFFieldValue() -> Data { Data() }
}

// MARK: - LXMessage

public final class LXMessage: @unchecked Sendable {
    // Field constants — match AI Swift surface (UInt8).
    public static let FIELD_ICON_APPEARANCE: UInt8 = 0x04
    public static let FIELD_FILE_ATTACHMENTS: UInt8 = 0x05
    public static let FIELD_IMAGE:            UInt8 = 0x06
    public static let FIELD_AUDIO:            UInt8 = 0x07
    public static let FIELD_TELEMETRY:        UInt8 = 0x08
    public static let FIELD_APP_DATA:         UInt8 = 0x10
    public static let FIELD_COLUMBA_META:     UInt8 = 0x70

    public let destinationHash: Data
    public var sourceHash: Data
    public var sourceIdentity: Identity?
    public var signature: Data
    public var timestamp: Double
    public var title: Data
    public var content: Data
    public var fields: [UInt8: Any]?
    public var stamp: Data?
    public var hash: Data
    public var state: LXMessageState
    public var method: LXDeliveryMethod
    public var representation: LXMessageRepresentation
    public var incoming: Bool
    public var packed: Data?
    public var signatureValidated: Bool
    public var unverifiedReason: LXUnverifiedReason?
    public var deliveryAttempts: Int = 0
    public var nextDeliveryAttempt: Date?
    public var progress: Double = 0.0
    public var fallbackMethod: LXDeliveryMethod?
    public var rssi: Double?
    public var snr: Double?
    public var q: Double?
    public var receivingInterface: String?
    public var desiredMethod: LXDeliveryMethod

    public init(
        destinationHash: Data,
        sourceIdentity: Identity?,
        content: Data,
        title: Data = Data(),
        fields: [UInt8: Any]? = nil,
        desiredMethod: LXDeliveryMethod = .opportunistic
    ) {
        self.destinationHash = destinationHash
        self.sourceIdentity = sourceIdentity
        self.sourceHash = sourceIdentity?.hash ?? Data()
        self.signature = Data()
        self.timestamp = Date().timeIntervalSince1970
        self.title = title
        self.content = content
        self.fields = fields
        self.stamp = nil
        self.hash = Data()
        self.state = .draft
        self.method = .unknown
        self.representation = .unknown
        self.incoming = false
        self.packed = nil
        self.signatureValidated = false
        self.unverifiedReason = nil
        self.fallbackMethod = nil
        self.desiredMethod = desiredMethod
    }

    /// Compatibility init mirroring AI-Swift's most common ctor with named `method:`.
    public convenience init(
        destinationHash: Data,
        sourceIdentity: Identity?,
        content: Data,
        title: Data = Data(),
        fields: [UInt8: Any]? = nil,
        method: LXDeliveryMethod
    ) {
        self.init(
            destinationHash: destinationHash,
            sourceIdentity: sourceIdentity,
            content: content,
            title: title,
            fields: fields,
            desiredMethod: method
        )
    }

    public func pack() throws -> Data { Data() }

    public static func unpackFromBytes(_ data: Data, sourceIdentity: Identity? = nil) throws -> LXMessage {
        LXMessage(destinationHash: Data(), sourceIdentity: sourceIdentity, content: Data())
    }

    public var contentAsString: String { String(data: content, encoding: .utf8) ?? "" }
    public var titleAsString: String { String(data: title, encoding: .utf8) ?? "" }
}

// MARK: - LXMRouter

public final class LXMRouter: @unchecked Sendable {
    public weak var delegate: LXMRouterDelegate?

    /// Set by AppServices once RNSBackendPy is ready.
    public var sendHook: ((LXMessage) async throws -> Void)?

    public init() {}
    public init(identity: Identity, databasePath: String) async throws {}

    public var outboundPropagationNode: Data?
    public var propagationStampCost: Int = 0

    public func setDelegate(_ delegate: LXMRouterDelegate) { self.delegate = delegate }
    public func setTransport(_ transport: ReticulumTransport) {}
    public func setRatchetManager(_ manager: RatchetManager?) {}
    public func setPropagationStampCost(_ cost: Int) async { self.propagationStampCost = cost }
    public func registerDeliveryDestination(_ destination: Destination) {}

    @discardableResult
    public func handleOutbound(_ message: LXMessage) async throws -> Bool {
        if let hook = sendHook { try await hook(message); return true }
        return false
    }

    /// Inout variant used by ViewModels that need the router to populate
    /// `hash` / `state` / `timestamp` on the message after pack.
    @discardableResult
    public func handleOutbound(_ message: inout LXMessage) async throws -> Bool {
        if let hook = sendHook { try await hook(message); return true }
        return false
    }

    public func restart() async {}
    /// Latest sync state — observed by PropagationNodeManager after a sync.
    public var syncState: PropagationTransferState {
        get async { PropagationTransferState() }
    }
    public func syncFromPropagationNode() async throws {}
    public func shutdown() async {}
}

/// PropagationTransferState — the LXMF propagation-node sync state observed
/// by PropagationNodeManager after each sync attempt. Canonical home now
/// lives in RNSAPI so LXSTSwift (and any future SwiftPM consumer) can also
/// see it; the ColumbaApp duplicate was removed.
public struct PropagationTransferState: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle, linking, linked, linkFailed, transferring, transferFailed, noPath, complete
    }
    public var state: State
    public var receivedMessages: Int
    public var errorDescription: String?
    public var lastSync: Date?
    public var progress: Double

    public init(state: State = .idle, receivedMessages: Int = 0,
                errorDescription: String? = nil, lastSync: Date? = nil, progress: Double = 0) {
        self.state = state
        self.receivedMessages = receivedMessages
        self.errorDescription = errorDescription
        self.lastSync = lastSync
        self.progress = progress
    }

    public var isSyncing: Bool {
        switch state {
        case .linking, .linked, .transferring: return true
        default: return false
        }
    }
}

/// InterfaceMode — controls Reticulum announce propagation per interface.
/// Identical rawValues to the upstream Python config so JSON encoding
/// round-trips. The duplicate in ColumbaApp/Services/InterfaceRepository.swift
/// was removed in favor of this canonical RNSAPI home.
public enum InterfaceMode: String, Codable, Sendable, Equatable, CaseIterable {
    case full = "full"
    case gateway = "gateway"
    case accessPoint = "access_point"
    case roaming = "roaming"
    case boundary = "boundary"

    public var displayName: String {
        switch self {
        case .full: return "Full"
        case .gateway: return "Gateway"
        case .accessPoint: return "Access Point"
        case .roaming: return "Roaming"
        case .boundary: return "Boundary"
        }
    }

    public var description: String {
        switch self {
        case .full: return "All features enabled"
        case .gateway: return "Path discovery for others"
        case .accessPoint: return "Quiet unless active"
        case .roaming: return "Mobile relative to others"
        case .boundary: return "Links dissimilar segments"
        }
    }
}

/// RNodeConfig — full BLE-device-name + radio-parameter set. The duplicate
/// in ColumbaApp/Services/InterfaceRepository.swift was removed.
public struct RNodeConfig: Codable, Equatable, Sendable {
    public var deviceName: String
    public var frequency: UInt32
    public var bandwidth: UInt32
    public var txPower: UInt8
    public var spreadingFactor: UInt8
    public var codingRate: UInt8
    public var stAlock: Float?
    public var ltAlock: Float?

    public func toRadioConfig() -> RadioConfig {
        RadioConfig(
            frequency: frequency,
            bandwidth: bandwidth,
            txPower: txPower,
            spreadingFactor: spreadingFactor,
            codingRate: codingRate,
            stAlock: stAlock,
            ltAlock: ltAlock
        )
    }

    public static var defaultUS915: RNodeConfig {
        RNodeConfig(
            deviceName: "",
            frequency: 915_000_000,
            bandwidth: 125_000,
            txPower: 17,
            spreadingFactor: 7,
            codingRate: 5,
            stAlock: nil,
            ltAlock: nil
        )
    }

    public init(
        deviceName: String = "",
        frequency: UInt32 = 0,
        bandwidth: UInt32 = 0,
        txPower: UInt8 = 0,
        spreadingFactor: UInt8 = 0,
        codingRate: UInt8 = 0,
        stAlock: Float? = nil,
        ltAlock: Float? = nil
    ) {
        self.deviceName = deviceName
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.txPower = txPower
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
        self.stAlock = stAlock
        self.ltAlock = ltAlock
    }
}

/// PeerLocation — shared location data received from a peer (or shared by
/// the local user). Canonical home is now RNSAPI; the duplicate in
/// ColumbaApp/Views/PlatformCompat.swift was removed.
public struct PeerLocation: Identifiable, Equatable, Sendable {
    public let id: Data
    public var displayName: String?
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var speed: Double
    public var bearing: Double
    public var accuracy: Double
    public var lastUpdate: Date
    public var iconAppearance: IconAppearance?

    public init(
        id: Data,
        displayName: String? = nil,
        latitude: Double,
        longitude: Double,
        altitude: Double = 0,
        speed: Double = 0,
        bearing: Double = 0,
        accuracy: Double = 0,
        lastUpdate: Date = Date(),
        iconAppearance: IconAppearance? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.bearing = bearing
        self.accuracy = accuracy
        self.lastUpdate = lastUpdate
        self.iconAppearance = iconAppearance
    }

    public var isStale: Bool { Date().timeIntervalSince(lastUpdate) > 300 }
    public var shortHash: String { id.prefix(4).map { String(format: "%02x", $0) }.joined() }
}

/// SharingDuration — duration choices for location-sharing sessions. The
/// duplicate in ColumbaApp/Views/PlatformCompat.swift was removed.
public enum SharingDuration: String, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes = "15 min"
    case oneHour = "1 hour"
    case fourHours = "4 hours"
    case untilMidnight = "Until midnight"
    case indefinite = "Until I stop"

    public var id: String { rawValue }

    public func calculateEndDate(from start: Date = Date()) -> Date? {
        switch self {
        case .fifteenMinutes: return start.addingTimeInterval(15 * 60)
        case .oneHour:        return start.addingTimeInterval(60 * 60)
        case .fourHours:      return start.addingTimeInterval(4 * 60 * 60)
        case .untilMidnight:
            var cal = Calendar.current
            cal.timeZone = .current
            return cal.nextDate(after: start, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
        case .indefinite: return nil
        }
    }
}

public protocol LXMRouterDelegate: AnyObject {
    func router(_ router: LXMRouter, didReceiveMessage message: LXMessage)
}

// MARK: - LXMFDatabase (stubs mirror the AI Swift surface exactly)

/// Minimum-viable in-memory persistence for LXMF messages and conversations.
/// Real SQLite-backed implementation lives in Phase 2; this is enough for the
/// smoke test (and the Python backend's first-light end-to-end run) — chats
/// list and message thread render from these in-memory maps.
public final class LXMFDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var conversations: [Data: ConversationRecord] = [:]
    private var messagesByConversation: [Data: [MessageRecord]] = [:]
    private var messagesById: [Data: MessageRecord] = [:]
    private var peerIcons: [Data: IconAppearance] = [:]

    public init(path: String) {}

    private func keyFor(_ message: LXMessage) -> Data {
        // Inbound: source is the peer. Outbound: destination is the peer.
        message.incoming ? message.sourceHash : message.destinationHash
    }

    public func saveMessage(_ message: LXMessage) throws {
        lock.lock(); defer { lock.unlock() }
        let convHash = keyFor(message)

        // Ensure conversation row exists.
        if conversations[convHash] == nil {
            conversations[convHash] = ConversationRecord(
                hash: convHash,
                displayName: "",
                lastMessageAt: Date(timeIntervalSince1970: message.timestamp),
                lastMessage: String(data: message.content, encoding: .utf8),
                unreadCount: message.incoming ? 1 : 0
            )
        } else {
            var conv = conversations[convHash]!
            conv.lastMessageAt = Date(timeIntervalSince1970: message.timestamp)
            conv.lastMessage = String(data: message.content, encoding: .utf8)
            if message.incoming { conv.unreadCount += 1 }
            conversations[convHash] = conv
        }

        let record = MessageRecord(
            id: message.hash,
            conversationHash: convHash,
            content: message.content,
            timestamp: message.timestamp,
            direction: message.incoming ? .inbound : .outbound,
            state: message.state.rawValue,
            messageId: message.hash,
            sourceHash: message.sourceHash,
            method: message.method.rawValue
        )
        messagesById[message.hash] = record
        messagesByConversation[convHash, default: []].append(record)
    }

    public func getMessage(id: Data) throws -> LXMessage? { nil }
    public func hasMessage(id: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return messagesById[id] != nil
    }
    public func getMessages(forConversation hash: Data, limit: Int = 50, offset: Int = 0) throws -> [LXMessage] { [] }
    public func updateMessageState(id: Data, state: LXMessageState) throws {
        lock.lock(); defer { lock.unlock() }
        if var rec = messagesById[id] {
            rec.state = state.rawValue
            messagesById[id] = rec
            if let idx = messagesByConversation[rec.conversationHash]?.firstIndex(where: { $0.id == id }) {
                messagesByConversation[rec.conversationHash]?[idx] = rec
            }
        }
    }
    public func deleteMessage(id messageId: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if let rec = messagesById.removeValue(forKey: messageId) {
            messagesByConversation[rec.conversationHash]?.removeAll { $0.id == messageId }
        }
    }
    public func getMessageRecord(id: Data) throws -> MessageRecord? {
        lock.lock(); defer { lock.unlock() }
        return messagesById[id]
    }
    public func getMessageRecords(forConversation hash: Data, limit: Int = 200, offset: Int = 0) throws -> [MessageRecord] {
        lock.lock(); defer { lock.unlock() }
        let all = messagesByConversation[hash] ?? []
        // DESC by timestamp — offset 0 returns the newest `limit` messages,
        // subsequent pages walk backward in time. Callers
        // (MessagingViewModel.loadMessages / loadMoreMessages) `.reversed()`
        // each page so the in-memory `messages` array ends up
        // [oldest .. newest] for top-down chat display, and
        // `loadMoreMessages` can insert older pages at the front.
        //
        // Before this was ASC, which combined with the caller's reverse
        // meant offset 0 fetched the OLDEST `limit` messages and put the
        // newest of THAT page at index 0 — so once a conversation passed
        // `limit` total messages, freshly-sent ones disappeared on reload
        // and ordering looked inverted.
        let sorted = all.sorted { $0.timestamp > $1.timestamp }
        let end = min(offset + limit, sorted.count)
        guard offset < end else { return [] }
        return Array(sorted[offset..<end])
    }

    public func getConversations(limit: Int = 100, offset: Int = 0) throws -> [ConversationRecord] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(conversations.values).sorted { $0.lastMessageTimestamp > $1.lastMessageTimestamp }
        let end = min(offset + limit, all.count)
        guard offset < end else { return [] }
        return Array(all[offset..<end])
    }
    public func getConversation(hash: Data) throws -> ConversationRecord? {
        lock.lock(); defer { lock.unlock() }
        return conversations[hash]
    }
    public func ensureConversation(hash: Data, displayName: String?) throws {
        lock.lock(); defer { lock.unlock() }
        if var conv = conversations[hash] {
            if let displayName, !displayName.isEmpty { conv.displayName = displayName }
            conversations[hash] = conv
        } else {
            conversations[hash] = ConversationRecord(
                hash: hash,
                displayName: displayName ?? "",
                lastMessageAt: nil,
                lastMessage: nil,
                unreadCount: 0
            )
        }
    }
    public func updateDisplayName(hash: Data, displayName: String?) throws {
        lock.lock(); defer { lock.unlock() }
        if var conv = conversations[hash] {
            conv.displayName = displayName ?? ""
            conversations[hash] = conv
        }
    }
    public func setFavorite(hash: Data, isFavorite: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if var conv = conversations[hash] {
            conv.isFavorite = isFavorite ? 1 : 0
            conversations[hash] = conv
        }
    }
    public func setPinned(hash: Data, isPinned: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if var conv = conversations[hash] {
            conv.isPinned = isPinned ? 1 : 0
            conversations[hash] = conv
        }
    }
    public func setUnreadCount(hash: Data, count: Int) throws {
        lock.lock(); defer { lock.unlock() }
        if var conv = conversations[hash] {
            conv.unreadCount = count
            conversations[hash] = conv
        }
    }
    public func markConversationRead(hash: Data) throws { try setUnreadCount(hash: hash, count: 0) }
    public func deleteConversation(hash: Data) throws {
        lock.lock(); defer { lock.unlock() }
        conversations.removeValue(forKey: hash)
        messagesByConversation.removeValue(forKey: hash)
        messagesById = messagesById.filter { $0.value.conversationHash != hash }
    }
    public func updateConversation(for message: LXMessage) throws {
        // saveMessage already updates the conversation row; this is a no-op for now.
    }

    public func updatePeerIcon(_ hash: Data, iconName: String, fgColor: String, bgColor: String) throws {
        lock.lock(); defer { lock.unlock() }
        peerIcons[hash] = IconAppearance(iconName: iconName, fgColor: fgColor, bgColor: bgColor)
    }
    public func getPeerIcon(_ hash: Data) throws -> IconAppearance? {
        lock.lock(); defer { lock.unlock() }
        return peerIcons[hash]
    }

    public func loadPendingOutbound() throws -> [LXMessage] { [] }
    public func loadFailedOutbound() throws -> [LXMessage] { [] }

    public func updateReplyToId(messageId: Data, replyToId: String) throws {
        lock.lock(); defer { lock.unlock() }
        if var rec = messagesById[messageId] {
            rec.replyToId = replyToId
            messagesById[messageId] = rec
        }
    }
    public func updateReactions(messageId: Data, reactionsJson: String) throws {
        lock.lock(); defer { lock.unlock() }
        if var rec = messagesById[messageId] {
            rec.reactionsJson = reactionsJson
            messagesById[messageId] = rec
        }
    }
    public func getReactionsJson(messageId: Data) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return messagesById[messageId]?.reactionsJson
    }
}

public struct ConversationRecord: Identifiable, Equatable, Sendable, Codable {
    public let hash: Data
    public var displayName: String
    public var isFavorite: Int
    public var isPinned: Int
    public var lastMessageAt: Date?
    public var lastMessage: String?
    public var unreadCount: Int
    public var iconName: String?
    public var iconFgColor: String?
    public var iconBgColor: String?

    /// Alias for `hash` used by older call sites that mirror Android's
    /// `Conversation.destinationHash`.
    public var destinationHash: Data { hash }

    /// Alias for `lastMessageAt`. Defaults to `.distantPast` if no message
    /// has been seen yet, so call sites can sort without unwrapping.
    public var lastMessageTimestamp: Date { lastMessageAt ?? .distantPast }

    /// Alias for `lastMessage`. Defaults to empty string for previews.
    public var lastMessagePreview: String { lastMessage ?? "" }

    public var id: Data { hash }

    public init(
        hash: Data,
        displayName: String = "",
        isFavorite: Int = 0,
        isPinned: Int = 0,
        lastMessageAt: Date? = nil,
        lastMessage: String? = nil,
        unreadCount: Int = 0,
        iconName: String? = nil,
        iconFgColor: String? = nil,
        iconBgColor: String? = nil
    ) {
        self.hash = hash
        self.displayName = displayName
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.lastMessageAt = lastMessageAt
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.iconName = iconName
        self.iconFgColor = iconFgColor
        self.iconBgColor = iconBgColor
    }
}

public struct MessageRecord: Identifiable, Equatable, Sendable, Codable {
    public let id: Data
    public let conversationHash: Data
    public var content: Data
    public var timestamp: Double
    public var direction: Direction
    /// Stored as raw string so it can be persisted directly to SQLite; matches
    /// AI-Swift's `LXMessageState.rawValue` semantics on the call sites.
    public var state: String
    public var messageId: Data
    public var sourceHash: Data
    /// Stored as raw string matching `LXDeliveryMethod.rawValue`.
    public var method: String
    public var rssi: Double?
    public var snr: Double?
    public var receivingInterface: String?
    public var replyToId: String?
    public var reactionsJson: String?
    public var packedLxmf: Data

    public enum Direction: String, Equatable, Sendable, Codable { case inbound, outbound }

    public init(
        id: Data,
        conversationHash: Data,
        content: Data,
        timestamp: Double,
        direction: Direction,
        state: String,
        messageId: Data = Data(),
        sourceHash: Data = Data(),
        method: String = "",
        rssi: Double? = nil,
        snr: Double? = nil,
        receivingInterface: String? = nil,
        replyToId: String? = nil,
        reactionsJson: String? = nil,
        packedLxmf: Data = Data()
    ) {
        self.id = id
        self.conversationHash = conversationHash
        self.content = content
        self.timestamp = timestamp
        self.direction = direction
        self.state = state
        self.messageId = messageId
        self.sourceHash = sourceHash
        self.method = method
        self.rssi = rssi
        self.snr = snr
        self.receivingInterface = receivingInterface
        self.replyToId = replyToId
        self.reactionsJson = reactionsJson
        self.packedLxmf = packedLxmf
    }
}

// MARK: - Transport

public final class ReticulumTransport: @unchecked Sendable {
    public var hwMtu: Int { 500 }
    public var radioRssi: Double? { nil }
    public var radioSnr: Double? { nil }
    public var radioQuality: Double? { nil }
    public var transportEnabled: Bool = false
    public var transportIdentityHash: Data?
    public var onDiagnostic: (@Sendable (String) -> Void)?

    public init() {}
    public init(identity: Identity? = nil, storagePath: String? = nil) {}
    public init(pathTable: PathTable) {}

    public func registerPathRequestHandler() async {}

    public func setOnInterfacePeerSpawned(_ callback: (@Sendable (String) async -> Void)?) {}
    public func setOnInterfaceConnected(_ callback: (@Sendable (String) async -> Void)?) {}
    public func setOnInterfaceAdded(_ callback: (@Sendable (String) async -> Void)?) {}
    public func setOnDiagnostic(_ callback: @escaping @Sendable (String) -> Void) {
        onDiagnostic = callback
    }

    // Registered interfaces — the Compat layer is a stub for ReticulumSwift's
    // transport, but Network Status UI still needs to know what's wired so
    // it can render the per-interface rows. AppServices calls add*Interface
    // for each enabled entity at startup and after Apply & Restart, the
    // transport mirrors them into `registeredInterfaces` keyed by id, and
    // `getInterfaceSnapshots()` reflects current state (state field is
    // mutated on the interface stub by `applyPythonInterfaceStatus`).
    private let _interfaceLock = NSLock()
    private var registeredInterfaces: [String: any NetworkInterface] = [:]
    private var registeredInterfaceTypes: [String: WireInterfaceType] = [:]

    // Python-discovered auxiliary interfaces — AutoInterfacePeer /
    // BLEPeer / etc. that RNS spawns dynamically and registers with
    // `RNS.Transport.interfaces` but Swift never explicitly adds. Pushed
    // here by `AppServices.applyPythonInterfaceStatus` each poll tick
    // (~2s) so getInterfaceSnapshots can include them.
    private var pythonAuxiliarySnapshots: [InterfaceSnapshot] = []

    public func setPythonAuxiliarySnapshots(_ snapshots: [InterfaceSnapshot]) {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        pythonAuxiliarySnapshots = snapshots
    }

    public func addInterface(_ interface: any NetworkInterface) async throws {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        registeredInterfaces[interface.id] = interface
        registeredInterfaceTypes[interface.id] = .tcp
    }
    public func removeInterface(id: String) async {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        registeredInterfaces.removeValue(forKey: id)
        registeredInterfaceTypes.removeValue(forKey: id)
    }
    public func addAutoInterface(_ autoInterface: AutoInterface) async throws {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        registeredInterfaces[autoInterface.id] = autoInterface
        registeredInterfaceTypes[autoInterface.id] = .autoInterface
    }
    public func addBLEInterface(_ bleInterface: BLEInterface) async throws {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        registeredInterfaces[bleInterface.id] = bleInterface
        registeredInterfaceTypes[bleInterface.id] = .ble
    }
    public func addMPCInterface(_ mpcInterface: MPCInterface) async throws {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        registeredInterfaces[mpcInterface.id] = mpcInterface
        registeredInterfaceTypes[mpcInterface.id] = .multipeerConnectivity
    }
    public func getInterface(id: String) -> (any NetworkInterface)? {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        return registeredInterfaces[id]
    }
    public var interfaceCount: Int {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        return registeredInterfaces.count
    }
    public var interfaceIds: [String] {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        return Array(registeredInterfaces.keys)
    }
    public func listInterfaceIds() async -> [String] { interfaceIds }
    public func getInterfaceName(for interfaceId: String) async -> String? {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        // Exact match on Swift-side entity ID — that's what
        // user-defined interfaces register under.
        if let direct = registeredInterfaces[interfaceId]?.name { return direct }
        // The Python side may pass us the RNS config section name
        // (e.g. "Hub-FFB1F1"), which PythonConfigWriter formats as
        // `<sanitized name>-<6 char entity id prefix>`. Strip that
        // suffix and try matching by the sanitized name. Avoids the
        // user seeing "Hub-FFB1F1" or "python-rns" in the UI.
        if let dash = interfaceId.lastIndex(of: "-") {
            let suffix = interfaceId[interfaceId.index(after: dash)...]
            let suffixIsHexId = suffix.count == 6
                && suffix.allSatisfy { $0.isHexDigit }
            if suffixIsHexId {
                let candidateName = String(interfaceId[..<dash])
                // Match by sanitized iface name. Same sanitize rules as
                // PythonConfigWriter so we don't accidentally false-match.
                let target = candidateName
                    .replacingOccurrences(of: "_", with: " ")
                for iface in registeredInterfaces.values {
                    let sanitized = iface.name
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: " ", with: "_")
                    if sanitized == candidateName || iface.name == target {
                        return iface.name
                    }
                }
                // No match — return the human portion anyway (better than
                // the raw section name with hex suffix).
                return candidateName.replacingOccurrences(of: "_", with: " ")
            }
        }
        // Fall through: leave the caller's value (likely something like
        // "AutoInterfacePeer[en0/fe80::xxxx]" which we want shown as-is).
        return nil
    }
    public func getInterfaceSnapshots() async -> [InterfaceSnapshot] {
        _interfaceLock.lock(); defer { _interfaceLock.unlock() }
        var out: [InterfaceSnapshot] = registeredInterfaces.values.map { iface in
            let wireType = registeredInterfaceTypes[iface.id] ?? .tcp
            let label: String
            switch wireType {
            case .tcp: label = "TCPClient"
            case .udp: label = "UDP"
            case .i2p: label = "I2P"
            case .autoInterface: label = "AutoInterface"
            case .rnode: label = "RNode"
            case .ble: label = "BLE"
            case .multipeerConnectivity: label = "Multipeer"
            }
            // The `NetworkInterface` protocol only carries `online`. Derive
            // a coarse state from that — `applyPythonInterfaceStatus` updates
            // the concrete iface's `online` flag from Python's view, so
            // `connected/disconnected` here lines up with the real picture.
            let state: InterfaceState = iface.online ? .connected : .disconnected
            return InterfaceSnapshot(
                id: iface.id,
                name: iface.name,
                online: iface.online,
                typeLabel: label,
                type: wireType,
                state: state,
                isAutoInterfacePeer: false,
                isBLEPeerInterface: false,
                peerAddress: nil,
                lastErrorDescription: nil
            )
        }
        // Append python-discovered auxiliary interfaces (AutoInterfacePeer,
        // BLEPeer, etc.) — these aren't user-configured rows so they don't
        // get added via add*Interface, but they should still render so the
        // user can see when LAN/BLE peer discovery is working.
        out.append(contentsOf: pythonAuxiliarySnapshots)
        return out
    }

    // ──────── Backend bridge hooks ────────
    //
    // AppServices installs these closures at startup. They translate the
    // Compat-layer transport API that callers like CallManager and the
    // lxst-swift Telephone speak into the Python-backed RNS world. Each is
    // optional: until installed, the methods below are no-ops (matches the
    // pre-bridge Phase 1b behavior) so the build can stay green while
    // wiring proceeds.

    public var registerDestinationHook: (@Sendable (Destination) async -> Void)?
    public var unregisterDestinationHook: (@Sendable (Data) -> Void)?
    public var registerDestinationLinkCallbackHook:
        (@Sendable (Data, @escaping @Sendable (Link) async -> Void) -> Void)?
    public var initiateLinkHook:
        (@Sendable (Destination, Identity) async throws -> Link)?

    public func isDestinationRegistered(_ hash: Data) async -> Bool { false }
    public func registeredDestinationHashes() -> [String] { [] }
    public func registeredLinkCallbackHashes() -> [String] { [] }
    public func registerDestination(_ destination: Destination) async {
        await registerDestinationHook?(destination)
    }
    public func registerDestinationLinkCallback(for destHash: Data, callback: @escaping @Sendable (Link) async -> Void) {
        registerDestinationLinkCallbackHook?(destHash, callback)
    }
    public func unregisterDestination(hash: Data) {
        unregisterDestinationHook?(hash)
    }
    public func isLocalDestination(_ hash: Data) -> Bool { false }
    public var destinationCount: Int { 0 }
    public func nextHopInterfaceHwMtu(for destinationHash: Data) async -> Int? { nil }

    public func initiateLink(to destination: Destination, identity: Identity) async throws -> Link {
        if let hook = initiateLinkHook {
            return try await hook(destination, identity)
        }
        return Link(identityHash: destination.identity?.hash ?? Data())
    }
    public func registerLink(_ link: Link) async {}
    public func unregisterLink(linkId: Data) {}
    public func getLink(linkId: Data) -> Link? { nil }
    public var activeLinkCount: Int { 0 }
    public var pendingLinkCount: Int { 0 }

    public func waitForPacketProof(packetHash: Data, timeout: TimeInterval = 15) async -> Bool { false }
    public func registerProofCallback(truncatedHash: Data, callback: @Sendable @escaping () async -> Void) {}
    public func removeProofCallback(truncatedHash: Data) {}

    public func send(packet: Packet) async throws {}
    public func send(packet: Packet, via interfaceId: String) async throws {}
    public func sendLinkData(packet: Packet) async throws {}
    public func sendToInterface(_ data: Data, interfaceId: String) async throws {}

    public func handleReceivedData(data: Data, from interfaceId: String) async {}
    public func receive(packet: Packet, from interfaceId: String) async {}
    public func startRetransmissionLoop() {}
    public func stopRetransmissionLoop() {}

    public func setTransportEnabled(_ enabled: Bool, identity: Identity? = nil) {
        self.transportEnabled = enabled
    }

    public func requestPath(_ destinationHash: Data) async {}
    public func requestPath(for destinationHash: Data) async {}

    /// Wait up to `timeout` seconds for a path to `destinationHash`. Stub
    /// returns `true` immediately so lxst-swift's outbound-call code path can
    /// flow through to the real `openLink` bridge call, where the Python
    /// RNS.Transport handles real path discovery + timeout.
    public func awaitPath(for destinationHash: Data, timeout: TimeInterval) async -> Bool {
        true
    }

    public func validateIFAC(raw: Data, interfaceId: String) -> Data? { nil }
    public func applyIFAC(raw: Data, interfaceId: String) -> Data { raw }
    public func registerAnnounceHandler(_ handler: AnnounceHandler) async {}
}

public struct InterfaceSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let online: Bool
    public let typeLabel: String
    public let type: WireInterfaceType
    public let state: InterfaceState
    public let isAutoInterfacePeer: Bool
    public let isBLEPeerInterface: Bool
    public let peerAddress: String?
    public let lastErrorDescription: String?

    public init(
        id: String,
        name: String,
        online: Bool,
        typeLabel: String,
        type: WireInterfaceType = .tcp,
        state: InterfaceState = .disconnected,
        isAutoInterfacePeer: Bool = false,
        isBLEPeerInterface: Bool = false,
        peerAddress: String? = nil,
        lastErrorDescription: String? = nil
    ) {
        self.id = id
        self.name = name
        self.online = online
        self.typeLabel = typeLabel
        self.type = type
        self.state = state
        self.isAutoInterfacePeer = isAutoInterfacePeer
        self.isBLEPeerInterface = isBLEPeerInterface
        self.peerAddress = peerAddress
        self.lastErrorDescription = lastErrorDescription
    }
}

// MARK: - PathTable

/// In-memory path table. Python's RNS.Transport.path_table is the source of
/// truth for the network state; AppServices.handlePythonEvent mirrors each
/// `announce` event into this Compat-layer table via `insert(_:)`. The
/// ContactsViewModel subscribes to `pathUpdates` (one AsyncStream per
/// subscriber) to render the Network tab.
public final class PathTable: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Data: PathEntry] = [:]
    private var continuations: [UUID: AsyncStream<PathEntry>.Continuation] = [:]

    public init() {}
    public init(databasePath: String) throws {}

    public func lookup(destinationHash: Data) async -> PathEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[destinationHash]
    }
    public func size() async -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
    public func allEntries() async -> [PathEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.values)
    }
    public func remove(_ destinationHash: Data) async {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: destinationHash)
    }
    public func removeAll() async {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    /// Insert or update a path entry. Keyed by `destinationHash`; replacing
    /// an existing entry yields the new copy to all live `pathUpdates`
    /// subscribers so the UI re-renders.
    public func insert(_ entry: PathEntry) async {
        lock.lock()
        entries[entry.destinationHash] = entry
        let continuationsCopy = continuations.values
        lock.unlock()
        for continuation in continuationsCopy {
            continuation.yield(entry)
        }
    }

    /// Stream of path-table updates. Each subscriber gets its own continuation;
    /// new inserts (and updates of existing entries) are broadcast to every
    /// active subscriber. Cancellation of the consumer task tears down the
    /// continuation.
    public var pathUpdates: AsyncStream<PathEntry> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            // Replay current entries so a late subscriber doesn't miss
            // announces that arrived before it started listening.
            let snapshot = Array(entries.values)
            lock.unlock()
            for entry in snapshot { continuation.yield(entry) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }
}

public struct PathEntry: Identifiable, Equatable, Sendable {
    public let destinationHash: Data
    public var displayName: String
    public var nextHop: Data
    public var hopCount: Int
    public var lastSeen: Date
    public var publicKeys: Data
    public var interfaceId: String
    public var appData: Data?
    public var expires: Date
    public var timestamp: Date
    public var detectedAspect: String?
    public var isLXMFPropagationNode: Bool
    public var isLXSTTelephony: Bool
    public var isKnownDestination: Bool

    public var id: Data { destinationHash }

    public init(
        destinationHash: Data,
        displayName: String = "",
        nextHop: Data = Data(),
        hopCount: Int = 0,
        lastSeen: Date = Date(),
        publicKeys: Data = Data(),
        interfaceId: String = "",
        appData: Data? = nil,
        expires: Date = Date.distantPast,
        timestamp: Date = Date.distantPast,
        detectedAspect: String? = nil,
        isLXMFPropagationNode: Bool = false,
        isLXSTTelephony: Bool = false,
        isKnownDestination: Bool = false
    ) {
        self.destinationHash = destinationHash
        self.displayName = displayName
        self.nextHop = nextHop
        self.hopCount = hopCount
        self.lastSeen = lastSeen
        self.publicKeys = publicKeys
        self.interfaceId = interfaceId
        self.appData = appData
        self.expires = expires
        self.timestamp = timestamp
        self.detectedAspect = detectedAspect
        self.isLXMFPropagationNode = isLXMFPropagationNode
        self.isLXSTTelephony = isLXSTTelephony
        self.isKnownDestination = isKnownDestination
    }
}

// MARK: - Interfaces

public protocol NetworkInterface: AnyObject, Sendable {
    var id: String { get }
    var name: String { get }
    var online: Bool { get }
}

public protocol InterfaceDelegate: AnyObject, Sendable {
    func interface(_ interface: any NetworkInterface, didChangeState state: InterfaceState) async
    func interface(_ interface: any NetworkInterface, didReceiveData data: Data) async
}

public final class TCPInterface: NetworkInterface, @unchecked Sendable {
    public let id: String
    public let name: String
    public var online: Bool = false
    public var state: InterfaceState = .disconnected
    public var lastErrorDescription: String?
    public var hwMtu: Int { 262144 }
    public var delegate: InterfaceDelegate?

    public init(config: InterfaceConfig) throws {
        self.id = config.id
        self.name = config.name
    }

    public func setDelegate(_ delegate: InterfaceDelegate) async { self.delegate = delegate }
    public func connect() async throws {}
    public func disconnect() async {}
    public func send(_ data: Data) async throws {}
    public func beginTunnelMode(send hook: @escaping @Sendable (Data) async -> Void) async {}
    public func endTunnelMode() async {}
}

public final class AutoInterface: NetworkInterface, @unchecked Sendable {
    public let id: String
    public let name: String
    public var online: Bool = false
    public var state: InterfaceState = .disconnected
    public var peerCount: Int = 0

    public init(config: InterfaceConfig) {
        self.id = config.id
        self.name = config.name
    }

    public func connect() async throws {}
    public func disconnect() async {}
}

/// Stub BLE driver — full implementation lands when BLE comes back online.
public final class CoreBluetoothBLEDriver: @unchecked Sendable {
    public let identityHash: Data
    public init(identityHash: Data) { self.identityHash = identityHash }
}

public final class BLEInterface: NetworkInterface, @unchecked Sendable {
    public let id: String
    public let name: String
    public var online: Bool = false
    public var state: InterfaceState = .disconnected
    public var peerCount: Int = 0

    public init(config: InterfaceConfig) {
        self.id = config.id
        self.name = config.name
    }

    public init(driver: Any, config: InterfaceConfig) {
        self.id = config.id
        self.name = config.name
    }

    public init(config: InterfaceConfig, driver: CoreBluetoothBLEDriver, transportIdentity: Data) {
        self.id = config.id
        self.name = config.name
    }

    public func connect() async throws {}
    public func disconnect() async {}
    public func getConnectionInfos() async -> [BLEConnectionInfo] { [] }
    public func disconnectPeer(identityHex: String) async {}
}

public final class RNodeInterface: NetworkInterface, @unchecked Sendable {
    public let id: String
    public let name: String
    public var online: Bool = false
    public var state: InterfaceState = .disconnected

    public init(config: RNodeConfig, name: String) {
        self.id = "rnode-\(name)"
        self.name = name
    }

    /// Compatibility init that mirrors the AppServices call site —
    /// constructs from a generic InterfaceConfig + uses host/port as
    /// the BLE device name.
    public init(config: InterfaceConfig) throws {
        self.id = config.id
        self.name = config.name
    }

    public func connect() async throws {}
    public func disconnect() async {}
    public func configureRadio(_ config: RadioConfig) async throws {}
}

public final class MPCInterface: NetworkInterface, @unchecked Sendable {
    public let id: String
    public let name: String
    public var online: Bool = false
    public var state: InterfaceState = .disconnected
    public var peerCount: Int = 0

    public init(serviceType: String) {
        self.id = "mpc-\(serviceType)"
        self.name = serviceType
    }

    public init(config: InterfaceConfig, displayName: String) {
        self.id = config.id
        self.name = displayName
    }

    public func connect() async throws {}
    public func disconnect() async {}
}

public struct InterfaceConfig: Sendable, Equatable {
    public let id: String
    public let name: String
    public let type: WireInterfaceType
    public let enabled: Bool
    public let mode: InterfaceMode
    public let host: String
    public let port: UInt16
    public let ifac: Data?
    public let announceRateTarget: TimeInterval?
    public let announceRateGrace: Int
    public let announceRatePenalty: TimeInterval?
    public let networkName: String?
    public let passphrase: String?

    public init(
        id: String,
        name: String,
        type: WireInterfaceType,
        enabled: Bool,
        mode: InterfaceMode = .full,
        host: String = "",
        port: UInt16 = 0,
        ifac: Data? = nil,
        announceRateTarget: TimeInterval? = nil,
        announceRateGrace: Int = 0,
        announceRatePenalty: TimeInterval? = nil,
        networkName: String? = nil,
        passphrase: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.enabled = enabled
        self.mode = mode
        self.host = host
        self.port = port
        self.ifac = ifac
        self.announceRateTarget = announceRateTarget
        self.announceRateGrace = announceRateGrace
        self.announceRatePenalty = announceRatePenalty
        self.networkName = networkName
        self.passphrase = passphrase
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

public enum SignalQuality: String, Equatable, Sendable {
    case excellent, good, fair, poor, unknown
}

// MARK: - Location / Telemetry stubs (v1; full impl in v1.1)

public final class LocationSharingManager: @unchecked Sendable {
    public var peerLocations: [Data: PeerLocation] = [:]
    public var activePeers: Set<Data> = []
    public var isSharingWithAnyone: Bool { false }
    public init() {}
    public func isSharing(with destinationHash: Data) -> Bool { false }
    public func startSharing(with destinationHash: Data) async {}
    public func startSharing(with destinationHash: Data, duration: SharingDuration) {}
    public func stopSharing(with destinationHash: Data) {}
    public func sharedTelemetry(for destinationHash: Data) -> TelemetryPacket? { nil }
    public func handleIncomingCease(from sourceHash: Data) async {}
    public func handleIncomingTelemetry(
        from peerHash: Data,
        packet: TelemetryPacket,
        displayName: String?,
        iconAppearance: IconAppearance? = nil
    ) {}
    public func stopAllSharing() async {}
    public func setBackgroundState(_ isBackground: Bool) {}
}

public struct TelemetryPacket: Equatable, Sendable {
    public let timestamp: Date
    public let payload: Data
    public init(timestamp: Date = Date(), payload: Data = Data()) {
        self.timestamp = timestamp
        self.payload = payload
    }

    public static func decode(from data: Data) -> TelemetryPacket? {
        TelemetryPacket(timestamp: Date(), payload: data)
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
        txPower: UInt8 = 0,
        spreadingFactor: UInt8 = 0,
        codingRate: UInt8 = 0,
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

// MARK: - Propagation

public struct PropagationNodeInfo: Identifiable, Equatable, Sendable, Codable {
    public let destinationHash: Data
    public var displayName: String?
    public var lastSeen: Date
    public var hopCount: Int
    public var perTransferLimit: Int
    public var perSyncLimit: Int
    public var stampCost: Int
    public var enabled: Bool

    public var id: Data { destinationHash }

    public init(
        destinationHash: Data = Data(),
        displayName: String? = nil,
        lastSeen: Date = Date(),
        hopCount: Int = 0,
        perTransferLimit: Int = 0,
        perSyncLimit: Int = 0,
        stampCost: Int = 0,
        enabled: Bool = true
    ) {
        self.destinationHash = destinationHash
        self.displayName = displayName
        self.lastSeen = lastSeen
        self.hopCount = hopCount
        self.perTransferLimit = perTransferLimit
        self.perSyncLimit = perSyncLimit
        self.stampCost = stampCost
        self.enabled = enabled
    }

    public static func parse(_ data: Data) -> PropagationNodeInfo? { nil }
    public static func parse(from data: Data) -> PropagationNodeInfo? { nil }
}

public enum PropagationState: String, Equatable, Sendable {
    case idle, syncing, error
}
