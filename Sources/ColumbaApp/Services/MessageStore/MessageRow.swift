//
//  MessageRow.swift
//  ColumbaApp
//
//  App-owned GRDB record for the shared `messages` table.
//
//  ── ANDROID-PARITY STORE (Track: app-owned store) ─────────────────────────
//  This is Columba's OWN copy of the GRDB message row. It is lifted verbatim
//  from the LXMFSwift package's `Storage/MessageRecord.swift` and re-scoped to
//  the app target so the store is app-owned and does NOT depend on the wire
//  library (LXMFSwift / ReticulumSwift) - the same shape as Android, whose
//  `:data` Room store has zero dependency on the RNS library.
//
//  The ONLY things removed from the lifted file are the two methods that
//  existed solely to serve the wire type and welded the store to LXMFSwift:
//  `init(from: LXMessage)` and `toLXMessage()`. The app maps to/from the RNSAPI
//  domain types itself (see MessageRepository), and the Network Extension's
//  embedded Python node writes this exact table directly (rns_bridge.py), so
//  the columns below are FROZEN and must stay byte-identical to the schema the
//  Python inbound writer targets.
//

import Foundation
import GRDB

/// Database record for LXMF messages.
///
/// Persists all fields of the message including the packed bytes
/// (`packed_lxmf`), which carries either the signed LXMF wire (rows the
/// Network-Extension backend persists) or the MessagePack field map (rows the
/// app / Python path persists). See `MessageRepository.mapRecord` /
/// `normalizedFieldMap` for the dual-meaning discriminator.
public struct MessageRow: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messages"

    // MARK: - Database Columns

    /// Message ID (hash, 32 bytes)
    public var messageId: Data

    /// Conversation destination hash (16 bytes)
    public var conversationHash: Data

    /// Message destination hash (16 bytes)
    public var destinationHash: Data

    /// Message source hash (16 bytes)
    public var sourceHash: Data

    /// Ed25519 signature (64 bytes)
    public var signature: Data

    /// Message timestamp (Unix time)
    public var timestamp: Double

    /// Message title (can be empty)
    public var title: Data

    /// Message content
    public var content: Data

    /// Fields dictionary (MessagePack encoded, optional)
    public var fields: Data?

    /// Proof-of-work stamp (optional)
    public var stamp: Data?

    /// Message state (raw byte; see `GRDBState`)
    public var state: UInt8

    /// Delivery method (raw byte; see `GRDBDeliveryMethod`)
    public var method: UInt8

    /// Number of delivery attempts
    public var deliveryAttempts: Int

    /// Send/receive progress (0.0 to 1.0)
    public var progress: Double

    /// True if incoming message, false if outbound
    public var incoming: Bool

    /// RSSI (signal strength, optional)
    public var rssi: Double?

    /// SNR (signal-to-noise ratio, optional)
    public var snr: Double?

    /// Link quality (optional)
    public var q: Double?

    /// Ratchet ID (optional)
    public var ratchetId: Data?

    /// Human-readable name of the interface that received this message
    public var receivingInterface: String?

    /// ID of the message this is a reply to (optional)
    public var replyToId: String?

    /// JSON-encoded reactions for this message (optional)
    public var reactionsJson: String?

    /// Packed LXMF wire format (or MessagePack field map) for retransmission
    public var packedLxmf: Data

    /// Record creation timestamp
    public var createdAt: Double

    /// Record update timestamp
    public var updatedAt: Double

    // MARK: - Column Mapping (snake_case to camelCase)

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case conversationHash = "conversation_hash"
        case destinationHash = "destination_hash"
        case sourceHash = "source_hash"
        case signature
        case timestamp
        case title
        case content
        case fields
        case stamp
        case state
        case method
        case deliveryAttempts = "delivery_attempts"
        case progress
        case incoming
        case rssi
        case snr
        case q
        case ratchetId = "ratchet_id"
        case receivingInterface = "receiving_interface"
        case replyToId = "reply_to_id"
        case reactionsJson = "reactions_json"
        case packedLxmf = "packed_lxmf"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // MARK: - Initialization

    /// Memberwise initializer. Rows are built by the caller (MessageRepository)
    /// from RNSAPI domain fields; there is intentionally NO wire-type (LXMessage)
    /// constructor here - that is exactly what welded the lifted record to the
    /// LXMFSwift library.
    public init(
        messageId: Data,
        conversationHash: Data,
        destinationHash: Data,
        sourceHash: Data,
        signature: Data,
        timestamp: Double,
        title: Data,
        content: Data,
        fields: Data?,
        stamp: Data?,
        state: UInt8,
        method: UInt8,
        deliveryAttempts: Int,
        progress: Double,
        incoming: Bool,
        rssi: Double?,
        snr: Double?,
        q: Double?,
        ratchetId: Data?,
        receivingInterface: String?,
        replyToId: String?,
        reactionsJson: String?,
        packedLxmf: Data,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.messageId = messageId
        self.conversationHash = conversationHash
        self.destinationHash = destinationHash
        self.sourceHash = sourceHash
        self.signature = signature
        self.timestamp = timestamp
        self.title = title
        self.content = content
        self.fields = fields
        self.stamp = stamp
        self.state = state
        self.method = method
        self.deliveryAttempts = deliveryAttempts
        self.progress = progress
        self.incoming = incoming
        self.rssi = rssi
        self.snr = snr
        self.q = q
        self.ratchetId = ratchetId
        self.receivingInterface = receivingInterface
        self.replyToId = replyToId
        self.reactionsJson = reactionsJson
        self.packedLxmf = packedLxmf
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
