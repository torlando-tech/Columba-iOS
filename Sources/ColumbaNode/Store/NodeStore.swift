//
//  NodeStore.swift
//  ColumbaNode
//
//  The one protocol-independent durable store (contract 5). SQLite WAL, foreign
//  keys, durable FULL commits. The app and the NE each open their own connection
//  to the SAME file in the App Group; this is the shared durable seam.
//
//  This is the engine-AGNOSTIC core: it stores the durable intent, runs
//  stage-first admission (contract 3), maintains the command ledger and the node
//  change index, and allocates LocalSequence. It does NOT talk to RNS. The node
//  owner injects an `AdmissionPolicy` to decide accept/reject for a NEW command
//  (capability/scope/revision/budget checks); the store commits that disposition
//  + the change index atomically.
//

import Foundation

/// Internal: unwrap a non-nil value or throw a storage error. (Not public; the
/// library must not depend on XCTest.)
func require<T>(_ value: T?, _ what: String) throws -> T {
    guard let v = value else {
        throw NodeError(code: .storageUnavailable, message: "missing \(what)")
    }
    return v
}

/// Outcome of `stage`. The facade gets the receipt on success (state == .staged,
/// whether fresh or idempotently re-read); a distinct failure for a body conflict.
public enum StageOutcome: Equatable {
    case staged(LocalReceipt)
    case conflict(NodeError)
}

/// A single change-index row (contract 5 read model).
public struct Change: Hashable, Sendable {
    public enum Entity: String, Sendable {
        case identity, message, conversation, operation
        case peer, telemetry, callHistory, configuration, blob, notification, collection
    }
    public let identityID: IdentityID?
    public let entity: Entity
    public let key: String
    public let revision: Counter
    public let removed: Bool
    public init(identityID: IdentityID?, entity: Entity, key: String, revision: Counter, removed: Bool) {
        self.identityID = identityID
        self.entity = entity
        self.key = key
        self.revision = revision
        self.removed = removed
    }
}

public struct ChangeTransaction: Hashable, Sendable {
    public let sequence: Counter
    public let changes: [Change]
    public init(sequence: Counter, changes: [Change]) {
        self.sequence = sequence
        self.changes = changes
    }
}

/// The injected admission decision for a NEW (not-yet-disposed) command. The node
/// owner validates capability/scope/revision/references/budget here. A rejection
/// is a committed record (contract 3.4); only a storage failure leaves the intent
/// unresolved.
public enum AdmissionDecision: Sendable {
    case accept(operationID: OperationID)
    case reject(NodeError)
}
public typealias AdmissionPolicy = @Sendable (Intent) -> AdmissionDecision

public final class NodeStore: @unchecked Sendable {
    private let conn: SQLiteConnection
    private let lock = NSLock()
    private var epoch: StoreEpoch
    private var schemaVersion: Int

    // MARK: - Open

    public enum StoreConfig {
        case file(String)
        case inMemory
    }

    public init(config: StoreConfig, schemaVersion: Int = 1) throws {
        let connection: SQLiteConnection
        switch config {
        case .file(let path): connection = try SQLiteConnection(path: path)
        case .inMemory:       connection = try SQLiteConnection(path: ":memory:")
        }
        self.conn = connection
        self.schemaVersion = schemaVersion
        self.epoch = StoreEpoch()   // placeholder; set to the real epoch below
        try Self.migrate(connection)
        // Existing store: read its epoch. Fresh store: mint one.
        if let stored = try Self.readMeta(connection, "epoch") {
            self.epoch = try require(StoreEpoch(wire: stored), "epoch")
        } else {
            let newEpoch = StoreEpoch()
            self.epoch = newEpoch
            try conn.run("INSERT INTO store_meta(key, value) VALUES(?, ?)", ["epoch", newEpoch.wire])
        }
    }

    public var epochValue: StoreEpoch { lock.lock(); defer { lock.unlock() }; return epoch }

    /// Migrate a fresh store to a new epoch (replacement/reset/restore). Normal
    /// migration preserves the epoch (contract 5).
    public func replaceEpoch() throws {
        lock.lock(); defer { lock.unlock() }
        let e = StoreEpoch()
        self.epoch = e
        try conn.run("UPDATE store_meta SET value=? WHERE key='epoch'", [e.wire])
    }

    // MARK: - Schema

    private static func migrate(_ conn: SQLiteConnection) throws {
        let ddl = """
        CREATE TABLE IF NOT EXISTS store_meta(
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS commands(
            store_epoch    TEXT NOT NULL,
            command_id     TEXT NOT NULL,
            canonical_body TEXT NOT NULL,   -- RFC 8785 bytes (as hex)
            body_digest    TEXT NOT NULL,   -- SHA-256 hex of canonical_body
            body_json      TEXT NOT NULL,   -- canonical UTF-8 (for re-read)
            created_at     INTEGER NOT NULL,
            expires_at     INTEGER,
            after_command  TEXT,
            command_tag    TEXT NOT NULL,
            state          TEXT NOT NULL,   -- staged | accepted | rejected | retired
            message_id     TEXT,
            operation_id   TEXT,
            local_sequence INTEGER,
            accepted_at    INTEGER,
            rejection_code TEXT,
            PRIMARY KEY(store_epoch, command_id)
        );
        CREATE TABLE IF NOT EXISTS change_index(
            sequence     INTEGER PRIMARY KEY AUTOINCREMENT,
            entity       TEXT NOT NULL,
            entity_key   TEXT NOT NULL,
            identity_id  TEXT,
            revision     INTEGER NOT NULL,
            removed      INTEGER NOT NULL,
            store_epoch  TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_change_seq ON change_index(sequence);
        """
        try conn.exec(ddl)
    }

    // MARK: - Stage (always runs before control IPC)

    /// Durable stage of an immutable intent (contract 3.1). Idempotent on
    /// (storeEpoch, commandID) + identical canonical body; a different body under
    /// the same key is `idempotencyConflict`.
    @discardableResult
    public func stage(_ intent: Intent) throws -> StageOutcome {
        lock.lock(); defer { lock.unlock() }
        guard intent.storeEpoch == epoch else {
            throw NodeError.storeReplaced()
        }
        let canonical = intent.canonicalData
        let digest = intent.canonicalDigest
        let bodyJSON = String(decoding: canonical, as: UTF8.self)
        let digestHex = digest.hex

        return try conn.transaction { [self] in
            // Look up existing intent under the same key.
            var existing: (digest: String, state: String, msgID: String?, opID: String?, created: Int64, localSeq: Int64?)? = nil
            try conn.query(
                "SELECT body_digest, state, message_id, operation_id, created_at, local_sequence FROM commands WHERE store_epoch=? AND command_id=?",
                [epoch.wire, intent.commandID.wire]) { _, get in
                let d = get(0).asString ?? ""
                let s = get(1).asString ?? "staged"
                let m = get(2).asString
                let o = get(3).asString
                let c = get(4).asInt ?? 0
                let ls = get(5).asInt
                existing = (d, s, m, o, c, ls)
            }
            if let ex = existing {
                if ex.digest == digestHex {
                    // Idempotent: return the original receipt (contract 3.2).
                    let receipt = Self.receiptFromRow(intent: intent, msgID: ex.msgID, opID: ex.opID, state: ex.state, stagedAt: ex.created, localSeq: ex.localSeq)
                    return .staged(receipt)
                } else {
                    return .conflict(NodeError.idempotencyConflict(intent.commandID))
                }
            }

            // Fresh intent: allocate LocalSequence for message-bearing commands.
            let isMessage = Self.isMessageCommand(intent.body)
            var localSeq: Int64? = nil
            if isMessage {
                let next: Int64 = (try conn.scalar("SELECT COALESCE(MAX(sequence),0)+1 FROM change_index", []).first?.asInt) ?? 1
                localSeq = next
                // Reserve the change_index sequence row for this staged message so
                // inbound receiptSequence gaps from outbound staging are harmless.
                try conn.run("INSERT INTO change_index(sequence, entity, entity_key, identity_id, revision, removed, store_epoch) VALUES(?,?,?,?,?,0,?)",
                             [next, Change.Entity.message.rawValue, intent.commandID.wire, Self.bodyIdentity(intent.body).map { $0.wire }, 0, epoch.wire])
            }

            let state = "staged"
            try conn.run(
                """
                INSERT INTO commands(store_epoch, command_id, canonical_body, body_digest, body_json,
                                     created_at, expires_at, after_command, command_tag, state,
                                     message_id, operation_id, local_sequence)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    epoch.wire, intent.commandID.wire, digestHex, digestHex, bodyJSON,
                    intent.createdAt.epochMillis, intent.expiresAt?.epochMillis,
                    intent.afterCommandID?.wire, intent.body.tagName, state,
                    isMessage ? intent.commandID.wire : nil,   // MessageID == CommandID (distinct types)
                    intent.commandID.wire,                    // OperationID == CommandID initially
                    localSeq,                                 // nil for non-message commands
                ])
            let receipt = LocalReceipt(
                commandID: intent.commandID,
                messageID: isMessage ? MessageID(intent.commandID.raw) : nil,
                operationID: OperationID(intent.commandID.raw),
                localSequence: localSeq.map { Counter(UInt64($0)) },
                state: .staged,
                stagedAt: intent.createdAt)
            return .staged(receipt)
        }
    }

    /// Atomically abandon a staged (not-yet-accepted) intent before admission
    /// (contract 3). No-op if already accepted.
    @discardableResult
    public func abandonBeforeAdmission(_ commandID: CommandID) throws -> Bool {
        let updated: Int64 = try conn.transaction { [self] in
            try conn.run(
                "UPDATE commands SET state='retired' WHERE store_epoch=? AND command_id=? AND state='staged'",
                [self.epoch.wire, commandID.wire])
        }
        return updated > 0
    }

    // MARK: - Admit (node owner runs this; checks ledger FIRST)

    /// Admit a staged command (contract 3.3-3.5). The ledger is checked FIRST:
    /// an already-disposed command returns its existing record even if capability
    /// / identity / expiry has since changed. A NEW command runs the injected
    /// policy; the resulting disposition + a change-index commit are atomic.
    @discardableResult
    public func admit(commandID: CommandID, policy: @escaping AdmissionPolicy) throws -> CommandRecord {
        lock.lock(); defer { lock.unlock() }
        return try conn.transaction { [self] in
            // Read the staged intent + existing disposition.
            var row: (state: String, digest: String, msgID: String?, opID: String?,
                      acceptedAt: Int64?, rejectCode: String?, canonical: String)? = nil
            try conn.query(
                "SELECT state, body_digest, message_id, operation_id, accepted_at, rejection_code, body_json FROM commands WHERE store_epoch=? AND command_id=?",
                [epoch.wire, commandID.wire]) { _, get in
                let s = get(0).asString ?? ""
                let d = get(1).asString ?? ""
                let m = get(2).asString
                let o = get(3).asString
                let a = get(4).asInt
                let r = get(5).asString
                let c = get(6).asString ?? ""
                row = (s, d, m, o, a, r, c)
            }
            guard let r = row else {
                throw NodeError(code: .notFound, field: "commandID", retry: .never,
                                message: "command \(commandID.wire) not staged under this epoch")
            }
            // Ledger already has a disposition → return it (idempotent, contract 3.3).
            if r.state != "staged" {
                return Self.recordFromRow(commandID: commandID, state: r.state, digest: r.digest,
                                           msgID: r.msgID, opID: r.opID, acceptedAt: r.acceptedAt,
                                           rejectCode: r.rejectCode)
            }
            // NEW command: run the injected admission policy.
            let intent = try Self.intentFromJSON(r.canonical)
            let decision = policy(intent)
            let seq = try allocateSequence()
            switch decision {
            case .accept(let operationID):
                try conn.run("UPDATE commands SET state='accepted', operation_id=?, accepted_at=? WHERE store_epoch=? AND command_id=?",
                             [operationID.wire, Int64(Date().timeIntervalSince1970 * 1000), epoch.wire, commandID.wire])
                try conn.run("INSERT INTO change_index(sequence, entity, entity_key, identity_id, revision, removed, store_epoch) VALUES(?,?,?,?,?,0,?)",
                             [seq, Change.Entity.operation.rawValue, commandID.wire, Self.bodyIdentity(intent.body).map { $0.wire }, 0, epoch.wire])
                let cursor = Cursor(storeEpoch: epoch, sequence: Counter(UInt64(seq)))
                return CommandRecord(commandID: commandID, bodyDigest: try require(Digest(hex: r.digest), "bodyDigest"),
                                     disposition: .accepted, acceptedAt: Instant(Int64(Date().timeIntervalSince1970 * 1000)),
                                     operationID: operationID, rejection: nil,
                                     committedThrough: cursor)
            case .reject(let error):
                try conn.run("UPDATE commands SET state='rejected', rejection_code=? WHERE store_epoch=? AND command_id=?",
                             [error.code.rawValue, epoch.wire, commandID.wire])
                try conn.run("INSERT INTO change_index(sequence, entity, entity_key, identity_id, revision, removed, store_epoch) VALUES(?,?,?,?,?,0,?)",
                             [seq, Change.Entity.operation.rawValue, commandID.wire, Self.bodyIdentity(intent.body).map { $0.wire }, 0, epoch.wire])
                let cursor = Cursor(storeEpoch: epoch, sequence: Counter(UInt64(seq)))
                return CommandRecord(commandID: commandID, bodyDigest: try require(Digest(hex: r.digest), "bodyDigest"),
                                     disposition: .rejected, acceptedAt: nil,
                                     operationID: nil, rejection: error,
                                     committedThrough: cursor)
            }
        }
    }

    // MARK: - Reads

    public func command(_ commandID: CommandID) throws -> CommandRecord? {
        lock.lock(); defer { lock.unlock() }
        var row: (state: String, digest: String, msgID: String?, opID: String?, acceptedAt: Int64?, rejectCode: String?)? = nil
        try conn.query(
            "SELECT state, body_digest, message_id, operation_id, accepted_at, rejection_code FROM commands WHERE store_epoch=? AND command_id=?",
            [epoch.wire, commandID.wire]) { _, get in
            row = (get(0).asString ?? "", get(1).asString ?? "", get(2).asString, get(3).asString, get(4).asInt, get(5).asString)
        }
        guard let r = row else { return nil }
        return Self.recordFromRow(commandID: commandID, state: r.state, digest: r.digest, msgID: r.msgID, opID: r.opID, acceptedAt: r.acceptedAt, rejectCode: r.rejectCode)
    }

    /// Read back the staged intent for a commandID (the node owner uses this to
    /// resolve an `admit`'s commandID against the shared store - contract 3.3).
    /// Returns nil if the command was not staged under this epoch.
    public func intent(for commandID: CommandID) throws -> Intent? {
        lock.lock(); defer { lock.unlock() }
        var canonical: String? = nil
        try conn.query(
            "SELECT body_json FROM commands WHERE store_epoch=? AND command_id=?",
            [epoch.wire, commandID.wire]) { _, get in
            canonical = get(0).asString
        }
        guard let c = canonical else { return nil }
        return try Self.intentFromJSON(c)
    }

    /// High-water cursor of the node change index for this epoch.
    public func highWater() -> Cursor {
        let seq: Int64 = (try? conn.scalar("SELECT COALESCE(MAX(sequence),0) FROM change_index", []).first?.asInt) ?? 0
        return Cursor(storeEpoch: epochValue, sequence: Counter(UInt64(max(0, seq))))
    }

    /// Node changes strictly after `cursor` (catch-up; contract 5).
    public func changes(after cursor: Cursor, limit: Int = 128) throws -> [ChangeTransaction] {
        lock.lock(); defer { lock.unlock() }
        var txns: [Int64: [Change]] = [:]
        var order: [Int64] = []
        try conn.query(
            "SELECT sequence, entity, entity_key, identity_id, revision, removed FROM change_index WHERE store_epoch=? AND sequence>? ORDER BY sequence ASC LIMIT ?",
            [epoch.wire, cursor.sequence.value, Int64(limit)]) { _, get in
            let seq = get(0).asInt ?? 0
            let entityRaw = get(1).asString ?? ""
            let key = get(2).asString ?? ""
            let idWire = get(3).asString
            let rev = get(4).asInt ?? 0
            let removed = (get(5).asInt) ?? 0
            let entity = Change.Entity(rawValue: entityRaw) ?? .collection
            let change = Change(identityID: idWire.flatMap { IdentityID(wire: $0) }, entity: entity, key: key,
                                revision: Counter(UInt64(rev)), removed: removed != 0)
            if txns[seq] == nil { order.append(seq) }
            txns[seq, default: []].append(change)
        }
        return order.map { ChangeTransaction(sequence: Counter(UInt64($0)), changes: txns[$0] ?? []) }
    }

    /// Commit the node owner's domain changes to the change index (contract 5:
    /// the node owner is the SOLE writer for the node group; the engine never
    /// writes the store directly). Each change is appended at `MAX(sequence)+1`,
    /// in the given order; returns the cursor through which the index is now
    /// committed (the last change's sequence), or `nil` if nothing was committed.
    /// An epoch mismatch fails closed (a store replaced mid-flight).
    @discardableResult
    public func commitChanges(_ changes: [EngineChange]) throws -> Cursor? {
        lock.lock(); defer { lock.unlock() }
        guard !changes.isEmpty else { return highWater() }
        var lastSeq: Int64 = 0
        try conn.transaction { [self] in
            for change in changes {
                let seq: Int64 = (try conn.scalar("SELECT COALESCE(MAX(sequence),0)+1 FROM change_index", []).first?.asInt) ?? 1
                lastSeq = seq
                try conn.run(
                    "INSERT INTO change_index(sequence, entity, entity_key, identity_id, revision, removed, store_epoch) VALUES(?,?,?,?,?,?,?)",
                    [seq, change.entity.rawValue, change.key,
                     change.identityID?.wire, change.revision.value, change.removed ? 1 : 0, epoch.wire])
            }
        }
        return Cursor(storeEpoch: epochValue, sequence: Counter(UInt64(max(0, lastSeq))))
    }

    // MARK: - helpers

    private func allocateSequence() throws -> Int64 {
        let next: Int64 = (try conn.scalar("SELECT COALESCE(MAX(sequence),0)+1 FROM change_index", []).first?.asInt) ?? 1
        return next
    }

    private static func isMessageCommand(_ c: Command) -> Bool {
        switch c {
        case .submitMessage, .retryMessage: return true
        default: return false
        }
    }

    private static func bodyIdentity(_ c: Command) -> IdentityID? {
        switch c {
        case .submitMessage(let s): return s.scope.identityID
        case .retryMessage(let r): return r.scope.identityID
        case .announce(let scope, _, _): return scope.identityID
        case .purgeHistory(let scope, _, _): return scope.identityID
        case .createIdentity(_, let id): return id
        case .setEnabledIdentities(_, let ids, _, _): return ids.first
        default: return nil
        }
    }

    private static func receiptFromRow(intent: Intent, msgID: String?, opID: String?, state: String, stagedAt: Int64, localSeq: Int64?) -> LocalReceipt {
        let s: LocalReceipt.State
        switch state {
        case "accepted": s = .accepted
        case "rejected": s = .rejected
        case "retired":  s = .abandoned
        default:         s = .staged
        }
        return LocalReceipt(
            commandID: intent.commandID,
            messageID: msgID.flatMap { MessageID(wire: $0) },
            operationID: opID.flatMap { OperationID(wire: $0) } ?? OperationID(intent.commandID.raw),
            localSequence: localSeq.map { Counter(UInt64($0)) },
            state: s,
            stagedAt: Instant(stagedAt))
    }

    private static func recordFromRow(commandID: CommandID, state: String, digest: String, msgID: String?, opID: String?, acceptedAt: Int64?, rejectCode: String?) -> CommandRecord {
        let disposition: CommandRecord.Disposition
        let rejection: NodeError?
        switch state {
        case "accepted": disposition = .accepted; rejection = nil
        case "rejected": disposition = .rejected; rejection = rejectCode.flatMap { NodeError.Code(rawValue: $0) }.map { NodeError(code: $0) }
        case "retired":  disposition = .retired;  rejection = nil
        default:         disposition = .rejected; rejection = NodeError(code: .notFound, message: "command not staged")
        }
        return CommandRecord(
            commandID: commandID,
            bodyDigest: Digest(hex: digest) ?? Digest(data: Data(repeating: 0, count: 32)),
            disposition: disposition,
            acceptedAt: acceptedAt.map { Instant($0) },
            operationID: opID.flatMap { OperationID(wire: $0) },
            rejection: rejection,
            committedThrough: nil)
    }

    private static func intentFromJSON(_ json: String) throws -> Intent {
        // Reconstruct from the stored canonical JSON via a tiny decoder for the
        // fields we persist. (Full command-body decoding is the control-channel
        // increment; stage/admit only need identity + tag for the change index.)
        let data = Data(json.utf8)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NodeError(code: .storageUnavailable, message: "unparseable stored intent")
        }
        let epochWire = str(obj["storeEpoch"]) ?? ""
        guard let epoch = StoreEpoch(wire: epochWire) else {
            throw NodeError(code: .storageUnavailable, message: "invalid storeEpoch")
        }
        let cmdWire = str(obj["commandID"]) ?? ""
        guard let cmd = CommandID(wire: cmdWire) else {
            throw NodeError(code: .storageUnavailable, message: "invalid commandID")
        }
        let created = Instant((obj["createdAt"] as? NSNumber)?.int64Value ?? 0)
        let body = try decodeCommand(obj["body"] as? [String: Any])
        return Intent(storeEpoch: epoch, commandID: cmd, createdAt: created,
                      expiresAt: (obj["expiresAt"] as? NSNumber).map { Instant($0.int64Value) },
                      afterCommandID: (obj["afterCommandID"] as? String).flatMap { CommandID(wire: $0) },
                      body: body)
    }

    /// `Any?` → `[String: Any]?` for JSONSerialization sub-dicts.
    private static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    /// `Any?` → `String?` (JSON strings).
    private static func str(_ v: Any?) -> String? { v as? String }

    private static func decodeCommand(_ b: [String: Any]?) throws -> Command {
        guard let b else { throw NodeError(code: .storageUnavailable, message: "missing body") }
        let tag = str(b["tag"]) ?? ""
        let v = dict(b["value"]) ?? [:]
        switch tag {
        case "submitMessage":
            let scopeDict = dict(v["scope"]) ?? [:]
            let idWire = str(scopeDict["identityID"]) ?? ""
            guard let identityID = IdentityID(wire: idWire) else {
                throw NodeError(code: .storageUnavailable, message: "invalid scope.identityID")
            }
            let scope = Scope(identityID: identityID)
            let destWire = str(v["destination"]) ?? ""
            guard let dest = DestinationHash(hex: destWire) else {
                throw NodeError(code: .storageUnavailable, message: "invalid destination")
            }
            let payload = try decodePayload(dict(v["payload"]))
            let d = dict(v["delivery"]) ?? [:]
            let delivery = DeliveryPolicy(
                preferred: DeliveryPolicy.Preferred(rawValue: str(d["preferred"]) ?? "automatic") ?? .automatic,
                allowPropagationFallback: (d["allowPropagationFallback"] as? Bool) ?? false,
                maxAttempts: NonNegative(UInt64((d["maxAttempts"] as? NSNumber)?.uint64Value ?? 1)),
                stampBudgetMs: NonNegative(UInt64((d["stampBudgetMs"] as? NSNumber)?.uint64Value ?? 0)))
            let deadline = (v["deadline"] as? NSNumber).map { Instant($0.int64Value) }
            return .submitMessage(submit: SubmitMessage(scope: scope, destination: dest, payload: payload, delivery: delivery, deadline: deadline))
        default:
            // Other commands are not exercised by the current slice; the store only
            // needs them to round-trip for admission idempotency, which compares the
            // digest (already stored), not the re-decoded body.
            throw NodeError(code: .unsupported, message: "command tag \(tag) not yet supported by the store")
        }
    }

    private static func decodePayload(_ p: [String: Any]?) throws -> MessagePayload {
        guard let p else { throw NodeError(code: .storageUnavailable, message: "missing payload") }
        let tag = str(p["tag"]) ?? ""
        let v = dict(p["value"]) ?? [:]
        switch tag {
        case "chat":
            let content = str(dict(v["content"])?["value"]) ?? ""
            let title = (str(dict(v["title"])?["value"])).flatMap { $0.isEmpty ? nil : $0 }
            return .chat(ChatPayload(title: title, content: content))
        default:
            return .chat(ChatPayload(title: nil, content: ""))
        }
    }

    private static func readMeta(_ conn: SQLiteConnection, _ key: String) throws -> String? {
        var out: String? = nil
        try conn.query("SELECT value FROM store_meta WHERE key=?", [key]) { _, get in
            out = get(0).asString
        }
        return out
    }
}
