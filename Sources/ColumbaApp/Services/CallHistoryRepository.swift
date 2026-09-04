//
//  CallHistoryRepository.swift
//  ColumbaApp
//
//  Actor that owns the `columba_call_history` table in the SAME `lxmf-swift.db`
//  GRDB file the rest of the app uses. Mirrors MessageRepository's pattern
//  (open a raw GRDB DatabasePool, create the table in init). GRDB-only — no
//  LXMFSwift import (which is walled off to MessageRepository.swift).
//
//  On iOS the app-process CallManager is the SOLE writer (there is no
//  out-of-process Python service here, unlike Android).
//

import Foundation
import GRDB

public actor CallHistoryRepository {

    private let pool: DatabasePool

    /// Production init: open the shared `lxmf-swift.db` at `grdbPath` (same file
    /// MessageRepository uses) and create the call-history table.
    public init(grdbPath: String) throws {
        var config = Configuration()
        config.defaultTransactionKind = .immediate
        config.foreignKeysEnabled = true
        config.observesSuspensionNotifications = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout=5000")
        }
        self.pool = try DatabasePool(path: grdbPath, configuration: config)
        try self.pool.write { db in
            try db.execute(sql: Self.createTableSQL)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_call_history_local_attempted
                    ON columba_call_history (local_identity_hash, attempted_at)
                """)
        }
    }

    /// Test-only convenience is NOT needed: the production `init(grdbPath:)` is
    /// the code under test. Tests open a unique temp-file DB via it (a file-backed
    /// DB is shared correctly across the pool's connections; an in-memory
    /// `DatabasePool` is not, because GRDB 6 removed the `useSingletonConnections`
    /// flag that used to force a single shared in-memory connection).

    private static let createTableSQL = """
        CREATE TABLE IF NOT EXISTS columba_call_history (
            call_attempt_id         TEXT PRIMARY KEY NOT NULL,
            local_identity_hash     TEXT NOT NULL,
            remote_identity_hash    TEXT NOT NULL,
            direction               TEXT NOT NULL,
            peer_display_name_snap  TEXT,
            codec_profile_code      INTEGER,
            attempted_at            REAL NOT NULL,
            ringing_at              REAL,
            connected_at            REAL,
            ended_at                REAL,
            outcome                 TEXT,
            failure_reason          TEXT
        )
        """

    public func close() { try? pool.close() }

    // MARK: writes (idempotent, milestone-only)

    /// Insert a new attempt. `INSERT OR IGNORE` makes a duplicate callback for the
    /// same `callAttemptId` invisible (Android parity: "duplicate callbacks remain
    /// invisible").
    @discardableResult
    public func insertAttempt(callAttemptId: String, localIdentityHash: String,
                              remoteIdentityHash: String, direction: CallHistoryDirection,
                              peerDisplayNameSnapshot: String?, codecProfileCode: Int?,
                              attemptedAt: Date) throws -> Bool {
        return try pool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO columba_call_history (call_attempt_id,
                    local_identity_hash, remote_identity_hash, direction,
                    peer_display_name_snap, codec_profile_code, attempted_at)
                VALUES (?,?,?,?,?,?,?)
                """,
                arguments: [callAttemptId, localIdentityHash, remoteIdentityHash,
                            direction.rawValue, peerDisplayNameSnapshot,
                            codecProfileCode,
                            attemptedAt.timeIntervalSince1970])
            // GRDB 6.x: `db.changesCount` = rows changed by the last statement
            // (0 when INSERT OR IGNORE found the primary key already present).
            return db.changesCount == 1
        }
    }

    /// Record the outgoing ringing milestone (first writer wins; no-op if already set).
    public func recordRinging(_ callAttemptId: String, at: Date) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE columba_call_history
                SET ringing_at = ?
                WHERE call_attempt_id = ? AND ringing_at IS NULL
                """, arguments: [at.timeIntervalSince1970, callAttemptId])
        }
    }

    /// Record the connection milestone (first writer wins; no-op if already set).
    public func recordConnected(_ callAttemptId: String, at: Date) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE columba_call_history
                SET connected_at = ?
                WHERE call_attempt_id = ? AND connected_at IS NULL
                """, arguments: [at.timeIntervalSince1970, callAttemptId])
        }
    }

    /// Finalize the attempt with its terminal outcome + end time (final, exactly-once).
    ///
    /// Ordering contract: `CallManager` enqueues every attempt's writes onto a
    /// single ordered chain (insert → milestones → end), so by the time this
    /// runs the row exists and the update matches. The `AND ended_at IS NULL`
    /// guard keeps a duplicated end callback from clobbering the stored outcome.
    public func recordEnd(_ callAttemptId: String, at: Date,
                          outcome: CallOutcome, failureReason: String? = nil) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE columba_call_history
                SET ended_at = ?, outcome = ?, failure_reason = ?
                WHERE call_attempt_id = ? AND ended_at IS NULL
                """, arguments: [at.timeIntervalSince1970, outcome.rawValue,
                                 failureReason, callAttemptId])
        }
    }

    // MARK: reads

    /// Newest-first, identity-scoped, optionally name/hash searched.
    /// Reads ONLY `columba_call_history` (no conversations join — see
    /// CallHistoryRecord for why enrichment is a view-layer concern).
    public func fetchHistory(localIdentityHash: String, query: String) throws -> [CallHistoryRecord] {
        try pool.read { db in
            var sql = """
                SELECT call_attempt_id, local_identity_hash, remote_identity_hash,
                       direction, peer_display_name_snap, codec_profile_code,
                       attempted_at, ringing_at, connected_at, ended_at,
                       outcome, failure_reason
                FROM columba_call_history
                WHERE local_identity_hash = ?
                """
            var args: [String] = [localIdentityHash]
            let q = query.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty {
                sql += """

                    AND (remote_identity_hash LIKE ? COLLATE NOCASE
                         OR peer_display_name_snap LIKE ? COLLATE NOCASE)
                    """
                let like = "%\(q)%"
                args.append(like); args.append(like)
            }
            sql += " ORDER BY attempted_at DESC"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map { row in
                    // Pull each column into an explicit typed local so the
                    // compiler never has to infer `row[...]` inside the record
                    // initializer (a big expression that trips the type-checker
                    // budget and cascades "Double/String must conform to
                    // FetchableRecord" onto the trailing args).
                    let callAttemptId = row["call_attempt_id"] as String
                    let localIdentityHash = row["local_identity_hash"] as String
                    let remoteIdentityHash = row["remote_identity_hash"] as String
                    let direction = CallHistoryDirection(rawValue: row["direction"] as String) ?? .outgoing
                    let peerDisplayNameSnapshot = row["peer_display_name_snap"] as String?
                    let codecProfileCode = row["codec_profile_code"] as Int?
                    let attemptedAt = Date(timeIntervalSince1970: row["attempted_at"] as Double)
                    let ringingAt = (row["ringing_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
                    let connectedAt = (row["connected_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
                    let endedAt = (row["ended_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
                    let outcome = (row["outcome"] as String?).flatMap { CallOutcome(rawValue: $0) }
                    let failureReason = row["failure_reason"] as String?
                    return CallHistoryRecord(
                        callAttemptId: callAttemptId,
                        localIdentityHash: localIdentityHash,
                        remoteIdentityHash: remoteIdentityHash,
                        direction: direction,
                        peerDisplayNameSnapshot: peerDisplayNameSnapshot,
                        codecProfileCode: codecProfileCode,
                        attemptedAt: attemptedAt,
                        ringingAt: ringingAt,
                        connectedAt: connectedAt,
                        endedAt: endedAt,
                        outcome: outcome,
                        failureReason: failureReason)
                }
        }
    }

    public func fetchRecord(_ callAttemptId: String, localIdentityHash: String)
        throws -> CallHistoryRecord? {
        try pool.read { db -> CallHistoryRecord? in
            let row = try Row.fetchOne(db, sql: """
                SELECT call_attempt_id, local_identity_hash, remote_identity_hash,
                       direction, peer_display_name_snap, codec_profile_code,
                       attempted_at, ringing_at, connected_at, ended_at,
                       outcome, failure_reason
                FROM columba_call_history
                WHERE call_attempt_id = ? AND local_identity_hash = ?
                """, arguments: [callAttemptId, localIdentityHash])
            guard let row else { return nil }
            // Explicit typed locals (see fetchHistory for why the in-arg form
            // trips the type-checker budget).
            let callAttemptId = row["call_attempt_id"] as String
            let localIdentityHash = row["local_identity_hash"] as String
            let remoteIdentityHash = row["remote_identity_hash"] as String
            let direction = CallHistoryDirection(rawValue: row["direction"] as String) ?? .outgoing
            let peerDisplayNameSnapshot = row["peer_display_name_snap"] as String?
            let codecProfileCode = row["codec_profile_code"] as Int?
            let attemptedAt = Date(timeIntervalSince1970: row["attempted_at"] as Double)
            let ringingAt = (row["ringing_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
            let connectedAt = (row["connected_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
            let endedAt = (row["ended_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
            let outcome = (row["outcome"] as String?).flatMap { CallOutcome(rawValue: $0) }
            let failureReason = row["failure_reason"] as String?
            return CallHistoryRecord(
                callAttemptId: callAttemptId,
                localIdentityHash: localIdentityHash,
                remoteIdentityHash: remoteIdentityHash,
                direction: direction,
                peerDisplayNameSnapshot: peerDisplayNameSnapshot,
                codecProfileCode: codecProfileCode,
                attemptedAt: attemptedAt,
                ringingAt: ringingAt,
                connectedAt: connectedAt,
                endedAt: endedAt,
                outcome: outcome,
                failureReason: failureReason)
        }
    }

    /// Hard-delete all history for one local identity ("Clear history").
    @discardableResult
    public func clearHistory(localIdentityHash: String) throws -> Int {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM columba_call_history WHERE local_identity_hash = ?",
                           arguments: [localIdentityHash])
            // GRDB 6.x: `db.changesCount` = rows changed by the last statement.
            return db.changesCount
        }
    }
}
