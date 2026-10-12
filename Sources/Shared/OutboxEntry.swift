import Foundation

/// Durable command data, shared unchanged by both node hosts.
public struct OutboxEntry: Codable, Sendable, Equatable {

    /// Lowercase-hex `lxmf.delivery` destination hash (mirrors
    /// `ProxyRequest.lxmfSend.destHashHex`).
    public let destHashHex: String

    /// Plaintext message body. Stored as `String` to match
    /// `ProxyRequest.lxmfSend.content` (the NE wraps it as `Data(content.utf8)`);
    /// JSON encodes it directly, no base64.
    public let content: String

    /// `RNSAPI.LXDeliveryMethod` raw value ("opportunistic" / "direct" /
    /// "propagated" / …), exactly as `ProxyRequest.lxmfSend.method` carries it. The
    /// NE maps it back via its `deliveryMethod(_:)` helper.
    public let method: String

    /// MessagePack-packed canonical LXMF field map (image / attachments / icon /
    /// reply / extras), pre-assembled APP-SIDE by `LxmfFieldCodec` — identical to
    /// `ProxyRequest.lxmfSend.fieldsData`. `nil` (or empty) means no fields. Stored
    /// optional here (rather than the wire type's non-optional empty-`Data`) so a
    /// no-fields entry serializes compactly; the drain site treats nil as empty.
    public let failureFallbackMethod: String?
    public let fieldsData: Data?

    /// App-computed message hash hex for dedup / reconciliation, when one is
    /// available - otherwise `nil`.
    ///
    /// In the Model B proxy path this is **always nil today**, and that is correct,
    /// not a TODO stub. The canonical LXMF message hash is
    /// `SHA256(destHash + sourceHash + msgpack([timestamp, title, content, fields]))`
    /// (see LXMF-swift `LXMessage.pack`), where `timestamp` is assigned at PACK
    /// time. Packing happens NE-side at drain (`PythonNodeEngine.lxmfSend` ->
    /// `rns_bridge.send_opportunistic`), and the proxy that enqueues here imports RNSAPI ONLY - it
    /// has no `Identity`, no LXMF-swift, and no pack-time timestamp, so it cannot
    /// compute the real hash. (The app's only "optimistic" id is a random `UUID` in
    /// `MessagingViewModel`, which is never passed down to the backend.) Dedup does
    /// NOT depend on this field: re-send safety is the receiver's responsibility
    /// (LXMF-swift caches seen inbound message hashes for ~1h and rejects
    /// duplicates), and the enqueue condition is gated to cases where the NE did NOT
    /// accept the send. The field is retained - optional - so a future track that
    /// threads the app's local id down to the proxy can populate it without a
    /// schema migration.
    public let messageHashHex: String?

    /// Stable submission id (architecture review P1 #6), assigned ONCE app-side at
    /// the logical-send origin and carried through BOTH the live IPC request and
    /// the durable-outbox fallback. The NE dedups on it: a send whose id is already
    /// recorded in `SentIdStore` is not re-sent, so a lost live reply followed by an
    /// outbox replay cannot double-send the same message.
    ///
    /// Optional so a pre-migration on-disk entry (written before this field existed)
    /// still decodes and is replayed once: `nil` means "no stable id" = always a
    /// replay target (its safety falls back to the receiver-side hash cache, as
    /// `messageHashHex` documents). A present id is checked against the store; an
    /// entry is replayed only when its id is NOT yet recorded.
    public let sendId: String?

    /// Wall-clock enqueue time (`Date().timeIntervalSince1970`), for diagnostics /
    /// future staleness pruning. NOT the LXMF pack timestamp (that's assigned
    /// NE-side at drain).
    public let createdAt: Double

    public init(
        destHashHex: String,
        content: String,
        method: String,
        fieldsData: Data?,
        messageHashHex: String?,
        sendId: String?,
        createdAt: Double,
        failureFallbackMethod: String? = nil
    ) {
        self.destHashHex = destHashHex
        self.content = content
        self.method = method
        self.fieldsData = fieldsData
        self.messageHashHex = messageHashHex
        self.sendId = sendId
        self.createdAt = createdAt
        self.failureFallbackMethod = failureFallbackMethod
    }

    /// A stable identity for a `sendId`-less (pre-migration / unknown-id) entry,
    /// used by the NE to prune the EXACT legacy entry it just confirmed sent. A
    /// nil id has no store id to prune against (`SentIdStore` can't be asked), so
    /// the entry must be removed by this key instead.
    ///
    /// The key includes `createdAt` so two entries with identical content (same
    /// destination, text, method, fields) but different enqueue times are
    /// distinct: pruning a confirmed-sent entry does not remove its identical
    /// sibling that failed, which would lose the failed message forever.
    public var legacyKey: String {
        let fieldsHex = fieldsData.map { data in
            data.map { String(format: "%02x", $0) }.joined()
        } ?? ""
        return [destHashHex, content, method, fieldsHex, createdAt.description].joined(separator: "\u{1F}")
    }

    /// Tolerant decode: an on-disk entry written before `sendId` existed (no key)
    /// decodes with `sendId == nil` (replayed once, as documented) rather than
    /// failing the whole drain. All other fields keep their synthesized semantics.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destHashHex = try c.decode(String.self, forKey: .destHashHex)
        content = try c.decode(String.self, forKey: .content)
        method = try c.decode(String.self, forKey: .method)
        failureFallbackMethod = try c.decodeIfPresent(String.self, forKey: .failureFallbackMethod)
        fieldsData = try c.decodeIfPresent(Data.self, forKey: .fieldsData)
        messageHashHex = try c.decodeIfPresent(String.self, forKey: .messageHashHex)
        sendId = try c.decodeIfPresent(String.self, forKey: .sendId)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
    }
}
