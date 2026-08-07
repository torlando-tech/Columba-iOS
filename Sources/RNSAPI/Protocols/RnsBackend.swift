//
//  RnsBackend.swift
//  RNSAPI
//
//  The backend-agnostic protocol seam — iOS analog of Columba Android's
//  `:rns-api` (`RnsCore` / `RnsTelephony` / `RnsTransportAdmin`). The UI talks to
//  `AppServices` (the `:rns-host` facade); `AppServices` talks to `any RnsBackend`.
//  Both backends conform and are selected at build time:
//    • RNSBackendPy   — embedded canonical Python RNS/LXMF
//    • RNSBackendSwift — native reticulum-swift / LXMF-swift
//
//  The neutral DTOs below replace the `PythonBridge.*`-namespaced ones so neither
//  the UI nor `AppServices` reference a concrete backend. Each backend maps its
//  own representation onto these.
//

import Foundation

// MARK: - DTOs

/// Parameters to boot a backend.
public struct StartParams: Sendable {
    public let configDir: String
    public let identityPath: String
    public let displayName: String
    public let identityBytes: Data?

    public init(configDir: String, identityPath: String, displayName: String, identityBytes: Data? = nil) {
        self.configDir = configDir
        self.identityPath = identityPath
        self.displayName = displayName
        self.identityBytes = identityBytes
    }
}

/// Local identity + LXMF delivery destination, learned at `start`.
public struct LocalInfo: Equatable, Sendable {
    public let identityHash: String
    public let destinationHash: String

    public init(identityHash: String, destinationHash: String) {
        self.identityHash = identityHash
        self.destinationHash = destinationHash
    }
}

/// Result of an opportunistic LXMF send. `queued.messageHash` is the real LXMF
/// message hash hex (empty if unavailable); callers persist the outbound row
/// under it so a later `.delivery` event can correlate.
public enum SendOutcome: Equatable, Sendable {
    case queued(messageHash: String)
    case requestingPath
    case badHash
    case notStarted
    case other(String)
}

/// Events a backend surfaces to the host (drained from a stream). Mirrors the
/// announce / inbound / delivery-proof / RNS.Link event set the UI + LXST voice
/// state machine consume.
public enum BackendEvent: Equatable, Sendable {
    case announce(destHash: String, appDataHex: String, aspect: String, publicKeysHex: String, interfaceName: String, hops: Int, t: Date)
    /// `fieldsPacked` is the inbound LXMF field map as MessagePack bytes (empty
    /// = no fields) — decode with `LxmfFieldCodec.unpack`. Carries telemetry /
    /// attachments / reactions / replies / icon / cease through the seam.
    case inbound(sourceHash: String, messageHash: String, content: String, title: String, fieldsPacked: Data, t: Date)
    case state(String, t: Date)
    /// Delivery lifecycle event for an outbound message. `method` is the
    /// effective transport used for this attempt and is independent of state.
    case delivery(messageHash: String, state: String, method: LXDeliveryMethod?, t: Date)
    // RNS.Link events — consumed by lxst-swift for voice calls.
    case linkState(linkId: Int, state: String, reason: String, inbound: Bool, t: Date)
    case linkPacket(linkId: Int, data: Data, t: Date)
    case linkIdentified(linkId: Int, identityHashHex: String, t: Date)
}

/// Outcome of a blocking propagation-node sync.
public struct PropagationSyncResult: Sendable, Equatable {
    public enum State: String, Sendable {
        case idle
        case pathRequested = "path_requested"
        case linkEstablishing = "link_establishing"
        case linkEstablished = "link_established"
        case requestSent = "request_sent"
        case receiving
        case responseReceived = "response_received"
        case complete
        case cancelled
        case noPath = "no_path"
        case linkFailed = "link_failed"
        case transferFailed = "transfer_failed"
        case noIdentityReceived = "no_identity_received"
        case noAccess = "no_access"
        case failed
        case noRouter = "no-router"
        case notStarted = "not-started"
        case noNode = "no-node"
        case unknown
    }
    public let ok: Bool
    public let state: State
    public let receivedMessages: Int
    public let reason: String

    public init(ok: Bool, state: State, receivedMessages: Int, reason: String) {
        self.ok = ok
        self.state = state
        self.receivedMessages = receivedMessages
        self.reason = reason
    }
}

/// Result of a one-shot NomadNet page fetch.
public struct NomadNetFetchResult: Sendable, Equatable {
    public enum Status: String, Sendable {
        case ok
        case noPath = "no-path"
        case linkFailed = "link-failed"
        case requestFailed = "request-failed"
        case timeout
        case badHash = "bad-hash"
        case notStarted = "not-started"
        case unknown
    }
    public let ok: Bool
    public let status: Status
    public let data: Data
    public let contentType: String

    public init(ok: Bool, status: Status, data: Data, contentType: String) {
        self.ok = ok
        self.status = status
        self.data = data
        self.contentType = contentType
    }
}

/// RNS Transport diagnostic snapshot — interfaces, online state, table sizes.
/// `Decodable` so the Python backend can decode its `status_json` straight into
/// it; the Swift backend builds it via the memberwise init.
public struct StatusSnapshot: Decodable, Sendable {
    public let started: Bool
    public let interfaces: [InterfaceStatus]
    public let destinationTableSize: Int?
    public let pathTableSize: Int?

    public init(started: Bool, interfaces: [InterfaceStatus], destinationTableSize: Int?, pathTableSize: Int?) {
        self.started = started
        self.interfaces = interfaces
        self.destinationTableSize = destinationTableSize
        self.pathTableSize = pathTableSize
    }

    public struct InterfaceStatus: Decodable, Sendable {
        public let sectionName: String
        public let name: String
        public let online: Bool
        public let rxBytes: Int
        public let txBytes: Int
        // Model B enrichment (nil on the Model A local-transport path): lets the
        // Network Status view reconstruct each row from the NE's interfaces.
        public let typeRaw: String?
        public let isBLEPeer: Bool?
        public let isAutoPeer: Bool?
        public let peerAddress: String?
        public let lastError: String?

        public init(sectionName: String, name: String, online: Bool, rxBytes: Int, txBytes: Int,
                    typeRaw: String? = nil, isBLEPeer: Bool? = nil, isAutoPeer: Bool? = nil,
                    peerAddress: String? = nil, lastError: String? = nil) {
            self.sectionName = sectionName
            self.name = name
            self.online = online
            self.rxBytes = rxBytes
            self.txBytes = txBytes
            self.typeRaw = typeRaw
            self.isBLEPeer = isBLEPeer
            self.isAutoPeer = isAutoPeer
            self.peerAddress = peerAddress
            self.lastError = lastError
        }

        enum CodingKeys: String, CodingKey {
            case sectionName = "section_name"
            case name, online
            case rxBytes = "rx_bytes"
            case txBytes = "tx_bytes"
            case typeRaw = "type"
            case isBLEPeer = "is_ble_peer"
            case isAutoPeer = "is_auto_peer"
            case peerAddress = "peer_address"
            case lastError = "last_error"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.sectionName = (try? c.decode(String?.self, forKey: .sectionName)) ?? ""
            self.name = (try? c.decode(String?.self, forKey: .name)) ?? ""
            self.online = (try? c.decode(Bool.self, forKey: .online)) ?? false
            self.rxBytes = (try? c.decode(Int.self, forKey: .rxBytes)) ?? 0
            self.txBytes = (try? c.decode(Int.self, forKey: .txBytes)) ?? 0
            self.typeRaw = try? c.decode(String.self, forKey: .typeRaw)
            self.isBLEPeer = try? c.decode(Bool.self, forKey: .isBLEPeer)
            self.isAutoPeer = try? c.decode(Bool.self, forKey: .isAutoPeer)
            self.peerAddress = try? c.decode(String.self, forKey: .peerAddress)
            self.lastError = try? c.decode(String.self, forKey: .lastError)
        }
    }

    enum CodingKeys: String, CodingKey {
        case started, interfaces
        case destinationTableSize = "destination_table_size"
        case pathTableSize = "path_table_size"
    }
}

// MARK: - Protocols (Android :rns-api parity — composed sub-interfaces)
//
// Mirrors Android Columba's rns-api: the umbrella `RnsBackend` composes focused
// sub-interfaces — `core` (RNS lifecycle/announce/status), `lxmf` (messaging),
// `telephony` (voice links), `telemetry` (location sharing), `nomadnet` (node
// browsing), `transportAdmin` (live interfaces). `RnsLxmf` / `RnsTelemetry` /
// `RnsNomadnet` live in their own files.

/// Core RNS lifecycle, announces, status. (LXMF messaging is `RnsLxmf`; NomadNet
/// is `RnsNomadnet`; telemetry is `RnsTelemetry`.)
public protocol RnsCore: AnyObject, Sendable {
    /// Local identity + delivery destination once started (nil before `start`).
    var localInfo: LocalInfo? { get }
    /// Stream of backend events (announce / inbound / delivery / link). The
    /// first subscription starts the drain.
    var events: AsyncStream<BackendEvent> { get }

    @discardableResult
    func start(_ params: StartParams) async throws -> LocalInfo
    func stop() async
    @discardableResult func announce(displayName: String) async throws -> Bool
    @discardableResult func announceTelephony(displayName: String) async throws -> Bool
    func statusSnapshot() async -> StatusSnapshot?
    @discardableResult func persist() async -> Bool

    /// Retain a verified peer public identity without requesting a network path.
    /// QR imports use this so a later propagated send can encrypt for an offline
    /// peer. Backends that do not own an identity cache may return false.
    @discardableResult
    func rememberPeerIdentity(destHashHex: String, publicKey: Data) async -> Bool

    /// Lowercase-hex destination hashes this node has actually registered
    /// (its `lxmf.delivery` destination, plus `lxst.telephony` where the backend
    /// surfaces it). Backend-neutral so the Network Extension's sniff-only
    /// destination filter matches the same set both backends register. Empty
    /// before `start`.
    func registeredDestinationHashes() async -> [String]

    /// Native Model B BLE peers (reticulum-swift's `BLEInterface` runs in the NE,
    /// which owns the peers). The dedicated BLE connections screen polls this.
    /// Backends without a native BLE interface return `[]` (default below) — only
    /// `ProxyRnsBackend` overrides it to query the NE over the proxy IPC.
    func bleConnections() async -> [BLEConnectionInfo]
}

public extension RnsCore {
    /// Default: no native BLE interface ⇒ no peers. Keeps the non-Model-B backends
    /// (Swift / Python) conforming without each needing a stub.
    func bleConnections() async -> [BLEConnectionInfo] { [] }

    @discardableResult
    func rememberPeerIdentity(destHashHex: String, publicKey: Data) async -> Bool { false }
}

/// RNS.Link operations backing LXST voice (the Swift state machine drives these;
/// the backend is the Link pipe).
public protocol RnsTelephony: AnyObject, Sendable {
    func openLink(destHashHex: String, aspect: String, identityPublicKeyHex: String?) async throws -> (ok: Bool, linkId: Int, reason: String)
    @discardableResult func linkSend(linkId: Int, data: Data) async throws -> Bool
    @discardableResult func linkIdentify(linkId: Int) async throws -> Bool
    @discardableResult func linkTeardown(linkId: Int) async throws -> Bool
}

/// Live interface hot add/remove on the running transport (no restart).
public protocol RnsTransportAdmin: AnyObject, Sendable {
    @discardableResult func addInterface(name: String) async throws -> (ok: Bool, reason: String)
    @discardableResult func removeInterface(name: String) async throws -> (ok: Bool, reason: String)
}

/// The umbrella the factory returns and `AppServices` holds. Composes the six
/// facets (Android `RnsBackend` parity) and exposes them as accessors so call
/// sites read `backend.lxmf.send…` / `backend.core.start…` like Android.
public protocol RnsBackend: RnsCore, RnsLxmf, RnsTelemetry, RnsNomadnet, RnsTelephony, RnsTransportAdmin {
    /// What this backend can do — drives UI capability gating.
    var capabilities: BackendCapabilities { get }
}

// Facet accessors — a composition view over the conforming backend (the backend
// implements every facet, so each accessor is just `self` viewed as that facet).
public extension RnsBackend {
    var core: RnsCore { self }
    var lxmf: RnsLxmf { self }
    var telephony: RnsTelephony { self }
    var telemetry: RnsTelemetry { self }
    var nomadnet: RnsNomadnet { self }
    var transportAdmin: RnsTransportAdmin { self }
}

public extension RnsTelephony {
    func openLink(destHashHex: String) async throws -> (ok: Bool, linkId: Int, reason: String) {
        try await openLink(destHashHex: destHashHex, aspect: "lxst.telephony", identityPublicKeyHex: nil)
    }
}
