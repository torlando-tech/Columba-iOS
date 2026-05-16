//
//  MsgPack.swift
//  RNSAPI
//
//  Minimal MessagePack implementation supporting the wire-format subset
//  Reticulum / LXMF / LXST use:
//    - nil, bool, ints (signed + unsigned, fixint and prefixed 1/2/4/8 byte),
//      bin (binary blobs), str (utf-8), array, map
//    - skipped: floats, ext types, timestamps (LXST wire format uses none)
//
//  Public entry points:
//    packMsgPack(_:) -> Data
//    unpackMsgPack(_:) -> MessagePackValue?
//
//  Mirrors the API shape from the deleted reticulum-swift package's
//  vendored MessagePack module so the lxst-swift sources that referenced
//  it compile against this drop-in replacement.

import Foundation

public enum MessagePackError: Error, Sendable {
    case malformedData
}

/// Pack a value into MessagePack-encoded bytes.
public func packMsgPack(_ value: MessagePackValue) -> Data {
    var out = Data()
    MsgPack.pack(value, into: &out)
    return out
}

/// Unpack a single MessagePack value from `data`. Throws if the bytes are
/// malformed or the prefix declares more bytes than are present. Throws
/// (rather than returning nil) so the canonical call site
/// `guard let v = try? unpackMsgPack(data) else { ... }` works without a
/// "no calls to throwing functions in 'try' expression" warning.
public func unpackMsgPack(_ data: Data) throws -> MessagePackValue {
    var cursor = MsgPack.Cursor(data: data, index: data.startIndex)
    guard let value = MsgPack.unpack(from: &cursor) else {
        throw MessagePackError.malformedData
    }
    return value
}

private enum MsgPack {
    struct Cursor {
        let data: Data
        var index: Data.Index

        mutating func readByte() -> UInt8? {
            guard index < data.endIndex else { return nil }
            let b = data[index]
            index = data.index(after: index)
            return b
        }

        mutating func readBytes(_ n: Int) -> Data? {
            let end = data.index(index, offsetBy: n, limitedBy: data.endIndex)
            guard let end else { return nil }
            let slice = data[index..<end]
            index = end
            return Data(slice)
        }

        mutating func readUInt(byteCount: Int) -> UInt64? {
            guard let bytes = readBytes(byteCount) else { return nil }
            var v: UInt64 = 0
            for b in bytes { v = (v << 8) | UInt64(b) }
            return v
        }

        mutating func readInt(byteCount: Int) -> Int64? {
            guard let raw = readUInt(byteCount: byteCount) else { return nil }
            // Sign-extend from `byteCount` bytes.
            let bits = byteCount * 8
            let signBit: UInt64 = 1 << (bits - 1)
            if raw & signBit != 0 {
                let mask: UInt64 = bits == 64 ? UInt64.max : (1 << bits) - 1
                let extended = raw | ~mask
                return Int64(bitPattern: extended)
            }
            return Int64(raw)
        }
    }

    // MARK: - Pack

    static func pack(_ value: MessagePackValue, into out: inout Data) {
        switch value {
        case .nil:
            out.append(0xc0)
        case .bool(let b):
            out.append(b ? 0xc3 : 0xc2)
        case .uint(let u):
            packUInt(u, into: &out)
        case .int(let i):
            packInt(i, into: &out)
        case .float(let f):
            out.append(0xca)
            var be = f.bitPattern.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        case .double(let d):
            out.append(0xcb)
            var be = d.bitPattern.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        case .string(let s):
            packStr(s, into: &out)
        case .binary(let d):
            packBin(d, into: &out)
        case .array(let arr):
            packArrayHeader(count: arr.count, into: &out)
            for v in arr { pack(v, into: &out) }
        case .map(let dict):
            packMapHeader(count: dict.count, into: &out)
            // Deterministic key ordering: sort by encoded-uint key when
            // present (LXST wire format keys are all small ints); falls
            // back to encoded-int / first-string key otherwise.
            let sortedKeys = dict.keys.sorted { lhs, rhs in
                msgpackSortKey(lhs) < msgpackSortKey(rhs)
            }
            for k in sortedKeys {
                pack(k, into: &out)
                if let v = dict[k] { pack(v, into: &out) }
            }
        }
    }

    private static func msgpackSortKey(_ v: MessagePackValue) -> String {
        switch v {
        case .uint(let u): return String(format: "0:%020d", u)
        case .int(let i):  return String(format: "1:%020d", i + (Int64.max / 2))
        case .string(let s): return "2:\(s)"
        default: return "3:"
        }
    }

    private static func packUInt(_ u: UInt64, into out: inout Data) {
        if u <= 0x7f {
            out.append(UInt8(u))
        } else if u <= UInt64(UInt8.max) {
            out.append(0xcc); out.append(UInt8(u))
        } else if u <= UInt64(UInt16.max) {
            out.append(0xcd); appendBigEndian(UInt16(u), into: &out)
        } else if u <= UInt64(UInt32.max) {
            out.append(0xce); appendBigEndian(UInt32(u), into: &out)
        } else {
            out.append(0xcf); appendBigEndian(u, into: &out)
        }
    }

    private static func packInt(_ i: Int64, into out: inout Data) {
        if i >= 0 { packUInt(UInt64(i), into: &out); return }
        if i >= -32 {
            out.append(UInt8(bitPattern: Int8(i)))
        } else if i >= Int64(Int8.min) {
            out.append(0xd0); out.append(UInt8(bitPattern: Int8(i)))
        } else if i >= Int64(Int16.min) {
            out.append(0xd1); appendBigEndian(UInt16(bitPattern: Int16(i)), into: &out)
        } else if i >= Int64(Int32.min) {
            out.append(0xd2); appendBigEndian(UInt32(bitPattern: Int32(i)), into: &out)
        } else {
            out.append(0xd3); appendBigEndian(UInt64(bitPattern: i), into: &out)
        }
    }

    private static func packStr(_ s: String, into out: inout Data) {
        let bytes = Data(s.utf8)
        let n = bytes.count
        if n <= 0x1f {
            out.append(0xa0 | UInt8(n))
        } else if n <= UInt8.max {
            out.append(0xd9); out.append(UInt8(n))
        } else if n <= UInt16.max {
            out.append(0xda); appendBigEndian(UInt16(n), into: &out)
        } else {
            out.append(0xdb); appendBigEndian(UInt32(n), into: &out)
        }
        out.append(bytes)
    }

    private static func packBin(_ d: Data, into out: inout Data) {
        let n = d.count
        if n <= UInt8.max {
            out.append(0xc4); out.append(UInt8(n))
        } else if n <= UInt16.max {
            out.append(0xc5); appendBigEndian(UInt16(n), into: &out)
        } else {
            out.append(0xc6); appendBigEndian(UInt32(n), into: &out)
        }
        out.append(d)
    }

    private static func packArrayHeader(count n: Int, into out: inout Data) {
        if n <= 0x0f {
            out.append(0x90 | UInt8(n))
        } else if n <= UInt16.max {
            out.append(0xdc); appendBigEndian(UInt16(n), into: &out)
        } else {
            out.append(0xdd); appendBigEndian(UInt32(n), into: &out)
        }
    }

    private static func packMapHeader(count n: Int, into out: inout Data) {
        if n <= 0x0f {
            out.append(0x80 | UInt8(n))
        } else if n <= UInt16.max {
            out.append(0xde); appendBigEndian(UInt16(n), into: &out)
        } else {
            out.append(0xdf); appendBigEndian(UInt32(n), into: &out)
        }
    }

    private static func appendBigEndian(_ v: UInt16, into out: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
    }
    private static func appendBigEndian(_ v: UInt32, into out: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
    }
    private static func appendBigEndian(_ v: UInt64, into out: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
    }

    // MARK: - Unpack

    static func unpack(from cursor: inout Cursor) -> MessagePackValue? {
        guard let prefix = cursor.readByte() else { return nil }
        switch prefix {
        case 0xc0: return .nil
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)

        // float32
        case 0xca:
            guard let bits = cursor.readUInt(byteCount: 4) else { return nil }
            return .float(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        // float64
        case 0xcb:
            guard let bits = cursor.readUInt(byteCount: 8) else { return nil }
            return .double(Double(bitPattern: bits))

        // uint family
        case 0xcc: return cursor.readUInt(byteCount: 1).map { .uint($0) }
        case 0xcd: return cursor.readUInt(byteCount: 2).map { .uint($0) }
        case 0xce: return cursor.readUInt(byteCount: 4).map { .uint($0) }
        case 0xcf: return cursor.readUInt(byteCount: 8).map { .uint($0) }

        // int family
        case 0xd0: return cursor.readInt(byteCount: 1).map { .int($0) }
        case 0xd1: return cursor.readInt(byteCount: 2).map { .int($0) }
        case 0xd2: return cursor.readInt(byteCount: 4).map { .int($0) }
        case 0xd3: return cursor.readInt(byteCount: 8).map { .int($0) }

        // bin family
        case 0xc4:
            guard let n = cursor.readUInt(byteCount: 1), let data = cursor.readBytes(Int(n)) else { return nil }
            return .binary(data)
        case 0xc5:
            guard let n = cursor.readUInt(byteCount: 2), let data = cursor.readBytes(Int(n)) else { return nil }
            return .binary(data)
        case 0xc6:
            guard let n = cursor.readUInt(byteCount: 4), let data = cursor.readBytes(Int(n)) else { return nil }
            return .binary(data)

        // str family
        case 0xd9:
            guard let n = cursor.readUInt(byteCount: 1), let bytes = cursor.readBytes(Int(n)) else { return nil }
            return .string(String(data: bytes, encoding: .utf8) ?? "")
        case 0xda:
            guard let n = cursor.readUInt(byteCount: 2), let bytes = cursor.readBytes(Int(n)) else { return nil }
            return .string(String(data: bytes, encoding: .utf8) ?? "")
        case 0xdb:
            guard let n = cursor.readUInt(byteCount: 4), let bytes = cursor.readBytes(Int(n)) else { return nil }
            return .string(String(data: bytes, encoding: .utf8) ?? "")

        // array family (16 / 32)
        case 0xdc:
            guard let n = cursor.readUInt(byteCount: 2) else { return nil }
            return unpackArray(count: Int(n), from: &cursor)
        case 0xdd:
            guard let n = cursor.readUInt(byteCount: 4) else { return nil }
            return unpackArray(count: Int(n), from: &cursor)

        // map family (16 / 32)
        case 0xde:
            guard let n = cursor.readUInt(byteCount: 2) else { return nil }
            return unpackMap(count: Int(n), from: &cursor)
        case 0xdf:
            guard let n = cursor.readUInt(byteCount: 4) else { return nil }
            return unpackMap(count: Int(n), from: &cursor)

        default:
            // fixint family
            if prefix & 0x80 == 0 {
                return .uint(UInt64(prefix)) // positive fixint
            }
            if prefix >= 0xe0 {
                return .int(Int64(Int8(bitPattern: prefix))) // negative fixint
            }
            // fixstr
            if prefix & 0xe0 == 0xa0 {
                let n = Int(prefix & 0x1f)
                guard let bytes = cursor.readBytes(n) else { return nil }
                return .string(String(data: bytes, encoding: .utf8) ?? "")
            }
            // fixarray
            if prefix & 0xf0 == 0x90 {
                let n = Int(prefix & 0x0f)
                return unpackArray(count: n, from: &cursor)
            }
            // fixmap
            if prefix & 0xf0 == 0x80 {
                let n = Int(prefix & 0x0f)
                return unpackMap(count: n, from: &cursor)
            }
            return nil
        }
    }

    private static func unpackArray(count: Int, from cursor: inout Cursor) -> MessagePackValue? {
        var items: [MessagePackValue] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            guard let v = unpack(from: &cursor) else { return nil }
            items.append(v)
        }
        return .array(items)
    }

    private static func unpackMap(count: Int, from cursor: inout Cursor) -> MessagePackValue? {
        var dict: [MessagePackValue: MessagePackValue] = [:]
        dict.reserveCapacity(count)
        for _ in 0..<count {
            guard let k = unpack(from: &cursor) else { return nil }
            guard let v = unpack(from: &cursor) else { return nil }
            dict[k] = v
        }
        return .map(dict)
    }
}
