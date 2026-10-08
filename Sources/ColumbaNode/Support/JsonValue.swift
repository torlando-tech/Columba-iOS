//
//  JsonValue.swift
//  ColumbaNode
//
//  A small, self-contained JSON value model + the RFC 8785 (JSON Canonicalization
//  Scheme) canonical encoder. The canonical encoder is the ONE place the command
//  body digest is produced (contract 3: "Byte-for-byte canonicalization belongs
//  in the one shared module; don't independently implement it in app and engine").
//
//  Pure Foundation, no app/UIKit/Python deps, so it builds + tests on Linux and
//  on-device alike.
//

import Foundation

/// A JSON value in its decoded form. Number is stored as its JCS decimal string so
/// the canonical form is exact (no float round-trip drift; contract 2: counters are
/// decimal strings on the wire).
public indirect enum JsonValue: Sendable, Equatable {
    case object([String: JsonValue])
    case array([JsonValue])
    case string(String)
    case number(String)   // JCS decimal representation
    case boolean(Bool)
    case null
}

extension JsonValue {
    /// Convenience constructors so call sites read naturally. Numbers are stored
    /// as their JCS decimal string (counters are decimal strings on the wire).
    public static func uint(_ v: UInt64) -> JsonValue { .number(String(v)) }
    public static func int(_ v: Int64) -> JsonValue { .number(String(v)) }
    public static func bool(_ v: Bool) -> JsonValue { .boolean(v) }

    /// Object-key lookup: `v["key"]` is the member value or nil (non-object -> nil).
    public subscript(key: String) -> JsonValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }
}

extension JsonValue {
    /// RFC 8785 (JCS) canonical serialization of this value.
    ///
    /// Rules implemented (subset sufficient for our records/commands, all of which
    /// use integer numbers + string keys):
    ///   - objects: keys sorted by UTF-8 (byte) lexicographic order (== UTF-16 code
    ///     unit order for valid JSON keys, per JCS), members emitted in that order,
    ///     no whitespace.
    ///   - numbers: emitted as-is (already decimal, no exponent / leading zero / +).
    ///   - strings: minimal escaping, non-ASCII emitted as raw UTF-8 (not \uXXXX).
    ///   - arrays: element order preserved (array order IS significant).
    ///   - literals: true / false / null.
    public func canonicalData() -> Data {
        var out = ""
        Self.writeCanonical(self, into: &out)
        return Data(out.utf8)
    }

    static func writeCanonical(_ v: JsonValue, into out: inout String) {
        switch v {
        case .null:
            out += "null"
        case .boolean(let b):
            out += b ? "true" : "false"
        case .string(let s):
            out += "\""
            out += Self.escapeString(s)
            out += "\""
        case .number(let n):
            out += n
        case .array(let arr):
            out += "["
            for (i, e) in arr.enumerated() {
                if i > 0 { out += "," }
                writeCanonical(e, into: &out)
            }
            out += "]"
        case .object(let obj):
            out += "{"
            // JCS: sort keys by code point; for valid JSON keys UTF-8 byte order
            // equals UTF-16 code-unit order. Sort by UTF-8 bytes to be exact.
            let keys = obj.keys.sorted { a, b in
                Self.bytesLess(Array(a.utf8), Array(b.utf8))
            }
            for (i, k) in keys.enumerated() {
                if i > 0 { out += "," }
                out += "\""
                out += Self.escapeString(k)
                out += "\":"
                if let e = obj[k] {
                    writeCanonical(e, into: &out)
                } else {
                    out += "null"   // unreachable (Dictionary key exists); keep canonical-safe
                }
            }
            out += "}"
        }
    }

    /// Lexicographic byte comparison.
    static func bytesLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let n = Swift.min(a.count, b.count)
        for i in 0..<n {
            if a[i] != b[i] { return a[i] < b[i] }
        }
        return a.count < b.count
    }

    /// Minimal JSON string escaping (RFC 8785 style: escape only `"` and `\` and
    /// the required control chars; emit non-ASCII as raw UTF-8).
    static func escapeString(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out
    }
}
