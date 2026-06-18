//
//  ProxyIPC.swift
//  Shared (compiled into BOTH ColumbaApp and ColumbaNetworkExtension)
//
//  Track A5b — the app↔NE IPC envelope for the Model B send path.
//
//  In Model B the Network Extension owns the canonical `lxmf.delivery`
//  destination + node (A5a's `NEReticulumNode`); the app becomes a thin client
//  that marshals node-owning operations (start / stop / announce / status /
//  persist / lxmf-send / …) to the NE over `NETunnelProviderSession
//  .sendProviderMessage`. This file defines the request/response wire types and
//  their JSON codec used by both ends:
//    • app side  → `ProxyRnsBackend` encodes a `ProxyRequest`, sends it, decodes
//      the `ProxyResponse`;
//    • NE side   → `PacketTunnelProvider.handleAppMessage` try-decodes a
//      `ProxyRequest`, dispatches to `NEReticulumNode`, encodes a
//      `ProxyResponse`.
//
//  ── COLLISION RULE (HARD) ────────────────────────────────────────────────────
//  This file imports Foundation ONLY. It is linked into BOTH targets, so it must
//  not pull in RNSAPI / ReticulumSwift / LXMFSwift (RNSAPI's Compat layer
//  redeclares reticulum-swift type names, and those modules aren't even linked
//  into the NE). Node-owning operations therefore cross the seam as already-
//  serialized scalars / `Data` (hex strings, msgpack-packed field bytes, JSON),
//  never as protocol objects — exactly how `BackendEvent` / the `RnsLxmf` seam
//  keep things `Sendable`.
//
//  ── FRAMING / DISAMBIGUATION ─────────────────────────────────────────────────
//  The PoC dumb-pipe (`PacketTunnelProvider.handleAppMessage`) interprets the
//  FIRST byte of an inbound message as a `FrameInterfaceTag` (tcp = 0x01,
//  auto = 0x02) and forwards the remainder onto an NWConnection. A ProxyRequest
//  must be unambiguously distinguishable from such a frame so the NE can
//  detect-or-fall-through. We reserve a dedicated leading MAGIC byte
//  (`ProxyIPC.magic` = 0xF5) that the PoC tag space never uses, followed by a
//  protocol VERSION byte, then the JSON-encoded `ProxyRequest`. `handleAppMessage`
//  checks the magic prefix first; only on a match does it parse a ProxyRequest,
//  otherwise it falls through to the existing frame-forwarding path untouched.
//

import Foundation

// MARK: - Envelope framing

/// Wire-framing constants + helpers for the app↔NE Model B IPC. Foundation-only
/// so it links into both targets. A request on the wire is:
///
///     [0xF5 magic][0x01 version][ JSON(ProxyRequest) … ]
///
/// and a response is the bare `JSON(ProxyResponse)` returned through the
/// `sendProviderMessage` completion handler (the response channel is already
/// 1:1 with the request, so it needs no magic/version framing — but it carries
/// its own `ProxyResponse` tag).
public enum ProxyIPC {

    /// Leading byte that marks a message as a Model B `ProxyRequest` envelope
    /// rather than a raw PoC interface frame. Chosen well outside the
    /// `FrameInterfaceTag` value space (tcp = 0x01, auto = 0x02) so
    /// `handleAppMessage` can branch on the first byte with zero ambiguity.
    public static let magic: UInt8 = 0xF5

    /// Envelope format version. Bump if the framing (not the Codable payload,
    /// which evolves additively) ever changes incompatibly.
    public static let version: UInt8 = 0x01

    /// JSON encoder/decoder shared by both ends. Plain JSON keeps the codec
    /// Foundation-only (no MessagePack dependency at the seam) and is trivially
    /// debuggable; `Data` payloads inside the request/response ride as base64
    /// via `Data`'s default `Codable` conformance.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: Request framing

    /// Encode a `ProxyRequest` into a magic+version-prefixed wire message.
    public static func encodeRequest(_ request: ProxyRequest) throws -> Data {
        var data = Data([magic, version])
        data.append(try encoder.encode(request))
        return data
    }

    /// True if `data` carries the Model B envelope magic prefix (i.e. it's a
    /// `ProxyRequest`, not a PoC frame). Cheap first-byte check used by
    /// `handleAppMessage` before attempting a decode.
    public static func isProxyRequest(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first == magic
    }

    /// Decode a magic+version-prefixed wire message back into a `ProxyRequest`.
    /// Returns `nil` if the magic/version prefix is absent or the version is
    /// unknown (caller falls through to the PoC path), and throws only if the
    /// prefix matched but the JSON body failed to decode.
    public static func decodeRequest(_ data: Data) throws -> ProxyRequest? {
        guard data.count >= 2, data[data.startIndex] == magic else { return nil }
        guard data[data.startIndex + 1] == version else { return nil }
        let body = data.dropFirst(2)
        return try decoder.decode(ProxyRequest.self, from: Data(body))
    }

    // MARK: Response framing

    /// Encode a `ProxyResponse` for the `sendProviderMessage` completion handler.
    public static func encodeResponse(_ response: ProxyResponse) -> Data {
        // The response is best-effort: if encoding ever failed we still want to
        // hand the app SOMETHING decodable, so fall back to a hand-rolled
        // `.error` JSON. (`ProxyResponse` is closed + all-Codable, so the throw
        // path is effectively unreachable; the fallback just removes `try` from
        // every NE call site.)
        if let data = try? encoder.encode(response) { return data }
        return Data(#"{"error":"encode-failed"}"#.utf8)
    }

    /// Decode a `ProxyResponse` returned by the NE. Returns `nil` on a nil /
    /// undecodable reply so the app can surface a transport-level failure.
    public static func decodeResponse(_ data: Data?) -> ProxyResponse? {
        guard let data, !data.isEmpty else { return nil }
        return try? decoder.decode(ProxyResponse.self, from: data)
    }
}

// MARK: - Request

/// A node-owning operation the app marshals to the NE under Model B. The set is
/// intentionally the A5b skeleton — the key lifecycle / announce / status /
/// persist / registered-hashes ops plus the primary `lxmfSend`. Richer ops
/// (reactions, telemetry, propagation sync, telephony links, nomadnet, transport
/// admin) are NOT proxied yet; `ProxyRnsBackend` answers those locally with an
/// `unsupportedInProxy` throw or a sensible no-op (see that type), so they never
/// reach this enum.
///
/// `Codable` via a discriminated union (`op` tag + flat associated fields). All
/// field types are JSON-native scalars or `Data` (base64), keeping the seam
/// Foundation-only and `Sendable`.
public enum ProxyRequest: Codable, Sendable, Equatable {

    /// Boot the NE node (mirrors `RnsCore.start`). The NE already loads the
    /// shared identity from the keychain group and computes the App-Group store
    /// path itself, so only the display name is marshaled; the response payload
    /// carries the learned `LocalInfo` (see `ProxyLocalInfo`).
    case start(displayName: String)

    /// Tear the NE node down (mirrors `RnsCore.stop`).
    case stop

    /// Emit an `lxmf.delivery` announce with the given display name
    /// (mirrors `RnsCore.announce`). Response payload: a Bool-as-JSON.
    case announce(displayName: String)

    /// Emit an `lxst.telephony` announce (mirrors `RnsCore.announceTelephony`).
    case announceTelephony(displayName: String)

    /// Transport diagnostic snapshot (mirrors `RnsCore.statusSnapshot`).
    /// Response payload: JSON-encoded `StatusSnapshot` (the NE encodes it with
    /// the same `snake_case` CodingKeys `StatusSnapshot` already declares, so the
    /// app decodes it straight back into `StatusSnapshot`).
    case statusSnapshot

    /// Flush pending router state to disk (mirrors `RnsCore.persist`).
    case persist

    /// Lowercase-hex destination hashes the NE node has registered
    /// (mirrors `RnsCore.registeredDestinationHashes`). Response payload:
    /// JSON `[String]`.
    case registeredDestinationHashes

    /// Heard-announce snapshot: the NE's PathTable entries for known aspects
    /// (lxmf.delivery / lxmf.propagation / lxst.telephony / nomadnetwork.node).
    /// The NE owns the transport in Model B, so the app can't hear announces
    /// itself — it polls this and re-emits `.announce` BackendEvents, exactly
    /// what `SwiftRNSBackend`'s PathTable poller does locally in Model A.
    /// Response payload: JSON `[ProxyHeardAnnounce]`.
    case heardAnnounces

    /// Send an LXMF message (mirrors `RnsLxmf.sendLxmfMessage`). The structured
    /// fields the typed seam carries (image / attachments / icon / reply) are
    /// pre-assembled by the APP into the canonical on-wire field map and passed
    /// as MessagePack-packed `fieldsData` (empty = no fields) so the NE doesn't
    /// need RNSAPI's `LxmfFieldCodec` at this seam. `method` is the
    /// `LXDeliveryMethod` raw value ("opportunistic" / "direct" / "propagated"
    /// / …). Response payload: JSON-encoded `ProxySendOutcome`.
    case lxmfSend(destHashHex: String, content: String, method: String, fieldsData: Data)

    /// Native Model B BLE peer snapshot. The NE owns reticulum-swift's
    /// `BLEInterface` in Model B (the app can't enumerate BLE peers itself), so
    /// the BLE connections screen polls this. Response payload: JSON
    /// `[BLEPeerSnapshot]`.
    case bleConnections

    // MARK: Codable (discriminated union)

    private enum CodingKeys: String, CodingKey {
        case op, displayName, destHashHex, content, method, fieldsData
    }

    /// Stable discriminator strings (decoupled from the Swift case names so a
    /// rename can't silently break the wire).
    private enum Op: String, Codable {
        case start, stop, announce, announceTelephony, statusSnapshot
        case persist, registeredDestinationHashes, lxmfSend, heardAnnounces
        case bleConnections
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .start(let displayName):
            try c.encode(Op.start, forKey: .op)
            try c.encode(displayName, forKey: .displayName)
        case .stop:
            try c.encode(Op.stop, forKey: .op)
        case .announce(let displayName):
            try c.encode(Op.announce, forKey: .op)
            try c.encode(displayName, forKey: .displayName)
        case .announceTelephony(let displayName):
            try c.encode(Op.announceTelephony, forKey: .op)
            try c.encode(displayName, forKey: .displayName)
        case .statusSnapshot:
            try c.encode(Op.statusSnapshot, forKey: .op)
        case .persist:
            try c.encode(Op.persist, forKey: .op)
        case .registeredDestinationHashes:
            try c.encode(Op.registeredDestinationHashes, forKey: .op)
        case .heardAnnounces:
            try c.encode(Op.heardAnnounces, forKey: .op)
        case .lxmfSend(let destHashHex, let content, let method, let fieldsData):
            try c.encode(Op.lxmfSend, forKey: .op)
            try c.encode(destHashHex, forKey: .destHashHex)
            try c.encode(content, forKey: .content)
            try c.encode(method, forKey: .method)
            try c.encode(fieldsData, forKey: .fieldsData)
        case .bleConnections:
            try c.encode(Op.bleConnections, forKey: .op)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(Op.self, forKey: .op)
        switch op {
        case .start:
            self = .start(displayName: try c.decode(String.self, forKey: .displayName))
        case .stop:
            self = .stop
        case .announce:
            self = .announce(displayName: try c.decode(String.self, forKey: .displayName))
        case .announceTelephony:
            self = .announceTelephony(displayName: try c.decode(String.self, forKey: .displayName))
        case .statusSnapshot:
            self = .statusSnapshot
        case .persist:
            self = .persist
        case .registeredDestinationHashes:
            self = .registeredDestinationHashes
        case .heardAnnounces:
            self = .heardAnnounces
        case .lxmfSend:
            self = .lxmfSend(
                destHashHex: try c.decode(String.self, forKey: .destHashHex),
                content: try c.decode(String.self, forKey: .content),
                method: try c.decode(String.self, forKey: .method),
                fieldsData: try c.decode(Data.self, forKey: .fieldsData)
            )
        case .bleConnections:
            self = .bleConnections
        }
    }
}

/// Wire DTO for one native Model B BLE peer (the NE's reticulum-swift
/// `BLEInterface.getConnectionInfos()` mapped to a `Codable` shape). The app maps
/// these onto its `BLEConnectionInfo` UI model in `ProxyRnsBackend.bleConnections()`.
public struct BLEPeerSnapshot: Codable, Sendable, Equatable {
    public let identityHash: String
    public let isOutgoing: Bool
    public let rssi: Int
    public let mtu: Int
    public let connectedAt: Date
    public let lastActivity: Date
    public let bytesSent: Int
    public let bytesReceived: Int
    public let packetsSent: Int
    public let packetsReceived: Int

    public init(identityHash: String, isOutgoing: Bool, rssi: Int, mtu: Int,
                connectedAt: Date, lastActivity: Date, bytesSent: Int,
                bytesReceived: Int, packetsSent: Int, packetsReceived: Int) {
        self.identityHash = identityHash
        self.isOutgoing = isOutgoing
        self.rssi = rssi
        self.mtu = mtu
        self.connectedAt = connectedAt
        self.lastActivity = lastActivity
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.packetsSent = packetsSent
        self.packetsReceived = packetsReceived
    }
}

// MARK: - Response

/// The NE's reply to a `ProxyRequest`. `.ok` optionally carries an op-specific
/// JSON payload (e.g. an encoded `ProxyLocalInfo` for `.start`, a `Bool` for
/// `.announce`, `StatusSnapshot` JSON for `.statusSnapshot`); `.error` carries a
/// human-readable reason; `.unsupported` means the NE node isn't running (or the
/// op isn't handled NE-side yet) so the app can degrade gracefully.
public enum ProxyResponse: Codable, Sendable, Equatable {
    case ok(Data?)
    case error(String)
    case unsupported

    private enum CodingKeys: String, CodingKey {
        case kind, payload, error
    }

    private enum Kind: String, Codable {
        case ok, error, unsupported
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok(let payload):
            try c.encode(Kind.ok, forKey: .kind)
            try c.encodeIfPresent(payload, forKey: .payload)
        case .error(let message):
            try c.encode(Kind.error, forKey: .kind)
            try c.encode(message, forKey: .error)
        case .unsupported:
            try c.encode(Kind.unsupported, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .ok:
            self = .ok(try c.decodeIfPresent(Data.self, forKey: .payload))
        case .error:
            self = .error(try c.decode(String.self, forKey: .error))
        case .unsupported:
            self = .unsupported
        }
    }
}

// MARK: - Payload DTOs (mirror the RNSAPI seam types, Foundation-only)
//
// These mirror the RNSAPI DTOs (`LocalInfo`, `SendOutcome`) the proxy needs to
// reconstruct, but are declared HERE (Foundation-only, `Codable`) so the wire
// codec doesn't depend on RNSAPI. `ProxyRnsBackend` maps these back onto the
// real `LocalInfo` / `SendOutcome`; the NE encodes them without ever importing
// RNSAPI. `StatusSnapshot` is NOT mirrored — it's already `Decodable` with
// stable `snake_case` keys, and only the APP side decodes it, so the NE encodes
// an equivalent JSON object inline.

/// `Codable` mirror of `RNSAPI.LocalInfo` for the `.start` response payload.
public struct ProxyLocalInfo: Codable, Sendable, Equatable {
    public let identityHash: String
    public let destinationHash: String
    public init(identityHash: String, destinationHash: String) {
        self.identityHash = identityHash
        self.destinationHash = destinationHash
    }
}

/// `Codable` mirror of `RNSAPI.SendOutcome` for the `.lxmfSend` response payload.
/// Encodes the case as a discriminator plus an optional associated string so the
/// app can reconstruct the exact `SendOutcome` case (including
/// `.queued(messageHash:)` and `.other(_)`).
public struct ProxySendOutcome: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case queued, requestingPath, badHash, notStarted, other
    }
    public let kind: Kind
    /// `messageHash` for `.queued`; the reason string for `.other`; nil otherwise.
    public let detail: String?

    public init(kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

/// `Codable` mirror of a heard announce — the fields of a `BackendEvent.announce`
/// — Foundation-only so it crosses the seam. The NE builds these from its
/// transport's PathTable (`heardAnnounces` response); `ProxyRnsBackend` polls and
/// re-emits each as a `.announce` event, so the app's existing announce handling
/// (`AppServices` `for await event in backend.events`) works unchanged in Model B.
public struct ProxyHeardAnnounce: Codable, Sendable, Equatable {
    public let destHashHex: String
    public let appDataHex: String
    public let aspect: String
    public let publicKeysHex: String
    public let interfaceName: String
    public let hops: Int
    /// Last-heard time, epoch seconds (the proxy diffs on this to emit only
    /// newly-seen / freshly re-announced destinations).
    public let timestamp: Double

    public init(destHashHex: String, appDataHex: String, aspect: String,
                publicKeysHex: String, interfaceName: String, hops: Int, timestamp: Double) {
        self.destHashHex = destHashHex
        self.appDataHex = appDataHex
        self.aspect = aspect
        self.publicKeysHex = publicKeysHex
        self.interfaceName = interfaceName
        self.hops = hops
        self.timestamp = timestamp
    }
}
