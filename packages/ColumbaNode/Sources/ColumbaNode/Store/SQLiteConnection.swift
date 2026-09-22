//
//  SQLiteStore.swift
//  ColumbaNode
//
//  A minimal, dependency-free SQLite wrapper (WAL, foreign keys, durable FULL
//  commits — contract 5). One connection per `NodeStore`; the app and the NE each
//  open their own connection to the SAME file in the App Group, which is the whole
//  point of the shared durable seam. The wrapper is deliberately small and correct
//  rather than feature-complete: parameterized statements only, no raw user SQL.
//

import Foundation
import SQLite3Shim

public enum SQLiteError: Error, Equatable {
    case openFailed(String)
    case exec(String)
    case bind(String)
    case step(String)
    case io(String)
}

public final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public convenience init(path: String) throws {
        try self.init(databaseFile: path)
    }

    private init(databaseFile: String) throws {
        // Create parent dir if needed.
        let url = URL(fileURLWithPath: databaseFile)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(databaseFile, &handle,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.openFailed("rc=\(rc) \(msg)")
        }
        self.db = handle
        // PRAGMAs from contract 5: WAL, foreign keys on, durable FULL commits.
        _ = try exec("PRAGMA journal_mode=WAL;")
        _ = try exec("PRAGMA foreign_keys=ON;")
        _ = try exec("PRAGMA synchronous=FULL;")
    }

    deinit { lock.lock(); if let db { sqlite3_close(db) }; lock.unlock() }

    // MARK: - Raw exec (DDL / PRAGMA / transactions)

    /// Run one or more statements with no parameters.
    @discardableResult
    public func exec(_ sql: String) throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        var errMsg: UnsafeMutablePointer<CChar>?
        var rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "rc=\(rc)"
            if let errMsg { sqlite3_free(errMsg) }
            throw SQLiteError.exec(msg)
        }
        return rc
    }

    /// Begin a transaction. Callers must `commit()` or `rollback()`.
    public func begin() throws { try exec("BEGIN IMMEDIATE;") }
    public func commit() throws { try exec("COMMIT;") }
    public func rollback() throws { try exec("ROLLBACK;") }

    /// Run a closure inside a transaction, committing on success, rolling back on
    /// throw. The caller's own connection is used (single-connection store).
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try begin()
        do {
            let r = try body()
            try commit()
            return r
        } catch {
            try? rollback()
            throw error
        }
    }

    // MARK: - Parameterized statements

    /// Bind one column value. Explicit `.null` means SQL NULL — no optional
    /// boxing, so NULL is unambiguous on every platform.
    ///
    /// TEXT/BLOB are copied IMMEDIATELY: we pass the exact byte length with the
    /// SQLITE_TRANSIENT destructor, so SQLite copies the bytes into its own
    /// storage during the bind call (the source `Data` is still alive for the
    /// whole closure). Binding with n = -1 would leave a pointer SQLite only
    /// dereferences at `sqlite3_step`, by which time a value-type UTF-8 buffer
    /// may already be gone (dangling read).
    private func bindValue(_ value: SQLValue, to stmt: OpaquePointer, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch value {
        case .null:
            sqlite3_bind_null(stmt, index)
        case let .text(s):
            let data = Data(s.utf8)
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let base = buf.baseAddress {
                    sqlite3_bind_text(stmt, index, base, Int32(buf.count), transient)
                } else {
                    // Empty string: bind a length-0 text with a valid pointer.
                    let one = Data([0x20])
                    one.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                        sqlite3_bind_text(stmt, index, b.baseAddress, 0, transient)
                    }
                }
            }
        case let .int64(i):
            sqlite3_bind_int64(stmt, index, i)
        case let .double(d):
            sqlite3_bind_double(stmt, index, d)
        case let .blob(data):
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), transient)
            }
        }
    }

    /// Run a statement (INSERT/UPDATE/DELETE) with parameters; returns rowid of
    /// the last inserted row (0 if none).
    @discardableResult
    public func run(_ sql: String, _ params: [any SQLConvertible]) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return try lockExec(sql, params: params.map { $0.toSQLValue() })
    }

    /// Run a query and invoke `row` for each result row. `row` receives the
    /// column count and a value getter.
    public func query(_ sql: String, _ params: [any SQLConvertible], _ row: (Int32, (Int32) -> SQLValue) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { throw SQLiteError.io("closed") }
        var stmtPtr: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmtPtr, nil)
        guard rc == SQLITE_OK, let stmt = stmtPtr else { throw SQLiteError.exec(errMsg()) }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            bindValue(p.toSQLValue(), to: stmt, at: Int32(i + 1))
        }
        while true {
            let r = sqlite3_step(stmt)
            if r == SQLITE_ROW {
                try row(Int32(sqlite3_column_count(stmt)), { idx in
                    Self.column(stmt, idx)
                })
            } else if r == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.step(errMsg())
            }
        }
    }

    /// Convenience: run a query returning a flat array of the first column.
    public func scalar(_ sql: String, _ params: [any SQLConvertible]) throws -> [SQLValue] {
        var out: [SQLValue] = []
        try query(sql, params) { _, get in
            out.append(get(0))
        }
        return out
    }

    // MARK: - internals (caller must hold lock)

    private func lockExec(_ sql: String, params: [SQLValue]) throws -> Int64 {
        guard let db = db else { throw SQLiteError.io("closed") }
        var stmtPtr: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmtPtr, nil)
        guard rc == SQLITE_OK, let stmt = stmtPtr else { throw SQLiteError.exec(errMsg()) }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            bindValue(p, to: stmt, at: Int32(i + 1))
        }
        let r = sqlite3_step(stmt)
        if r == SQLITE_DONE || r == SQLITE_ROW {
            // `changes()` = rows modified by THIS statement (INSERT=1,
            // UPDATE/DELETE = matched rows). last_insert_rowid is stale after an
            // UPDATE, so it must not be used for "did it change" tests.
            return Int64(sqlite3_changes(db))
        }
        throw SQLiteError.step(errMsg())
    }

    private func errMsg() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private static func column(_ stmt: OpaquePointer, _ idx: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, idx) {
        case SQLITE_INTEGER: return .int64(sqlite3_column_int64(stmt, idx))
        case SQLITE_FLOAT:   return .double(sqlite3_column_double(stmt, idx))
        case SQLITE_TEXT:
            let c = sqlite3_column_text(stmt, idx)
            return c.map { .text(String(cString: $0)) } ?? .null
        case SQLITE_BLOB:
            let bytes = sqlite3_column_blob(stmt, idx)
            let n = sqlite3_column_bytes(stmt, idx)
            if let bytes { return .blob(Data(bytes: bytes, count: Int(n))) }
            return .null
        default:
            return .null
        }
    }
}

/// A typed SQLite column/parameter value. Explicit `.null` avoids the ambiguity
/// of a nil optional boxed into `Any?` (which bridges to NSNull on Linux but a
/// wrapped-nil `Any` on Darwin).
public enum SQLValue: Sendable {
    case null
    case text(String)
    case int64(Int64)
    case double(Double)
    case blob(Data)

    public init(_ s: String) { self = .text(s) }
    public init(_ i: Int64) { self = .int64(i) }
    public init(_ i: Int) { self = .int64(Int64(i)) }
    public init(_ u: UInt64) { self = .int64(Int64(bitPattern: u)) }
    public init(_ b: Bool) { self = .int64(b ? 1 : 0) }
    public init(_ d: Double) { self = .double(d) }
    public init(_ data: Data) { self = .blob(data) }

    public var asString: String? { if case .text(let s) = self { return s }; return nil }
    public var asInt: Int64? { if case .int64(let i) = self { return i }; return nil }
    public var asDouble: Double? { if case .double(let d) = self { return d }; return nil }
    public var asData: Data? { if case .blob(let d) = self { return d }; return nil }
}

/// A value the store can bind as a SQL parameter. Conformances let call sites
/// pass ordinary `[String]` / mixed `[String, Int64, ...]` array literals
/// directly (heterogeneous literals infer as `[any SQLConvertible]`).
public protocol SQLConvertible: Sendable {
    func toSQLValue() -> SQLValue
}
extension String: SQLConvertible { public func toSQLValue() -> SQLValue { .text(self) } }
extension Int: SQLConvertible { public func toSQLValue() -> SQLValue { .int64(Int64(self)) } }
extension Int64: SQLConvertible { public func toSQLValue() -> SQLValue { .int64(self) } }
extension UInt64: SQLConvertible { public func toSQLValue() -> SQLValue { .int64(Int64(bitPattern: self)) } }
extension Double: SQLConvertible { public func toSQLValue() -> SQLValue { .double(self) } }
extension Bool: SQLConvertible { public func toSQLValue() -> SQLValue { .int64(self ? 1 : 0) } }
extension Data: SQLConvertible { public func toSQLValue() -> SQLValue { .blob(self) } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    public func toSQLValue() -> SQLValue {
        switch self { case .some(let w): return w.toSQLValue(); case .none: return .null }
    }
}
