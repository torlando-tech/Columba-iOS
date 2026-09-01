//
//  LxmfFieldCodec.swift
//  RNSAPI
//
//  Lossless `[UInt8: Any]` ⇄ MessagePack-`Data` codec for carrying an LXMF
//  field map across the `Sendable` backend seam (`BackendEvent.inbound`'s
//  `fieldsPacked`). Android serializes the field map to a JSON string
//  (`AppDataParser.serializeFieldsToJson`); iOS uses MessagePack instead so the
//  round-trip is *type-lossless* — `binary` stays `Data` and `string` stays
//  `String` (a JSON round-trip can't tell a hex-encoded byte field from a
//  literal string without per-field-id knowledge, which `IncomingMessageHandler`
//  shouldn't need). The packed bytes never cross to Android (the LXMF wire is
//  already MessagePack), so the representation choice is purely internal.
//
//  Reuses RNSAPI's own `packMsgPack`/`unpackMsgPack` (Util/MsgPack.swift), so no
//  backend-specific (ReticulumSwift / LXMF-swift) dependency leaks into the
//  neutral layer or `AppServices`.
//

import Foundation

public enum LxmfFieldCodec {

    /// Pack an LXMF field map to MessagePack bytes. Returns empty `Data` for an
    /// empty map (callers treat empty `fieldsPacked` as "no fields").
    public static func pack(_ fields: [UInt8: Any]) -> Data {
        guard !fields.isEmpty else { return Data() }
        return packMsgPack(value(fromFieldMap: fields))
    }

    /// Build the canonical on-wire LXMF field map from typed send params, shared
    /// by both backends so they encode identically: FIELD_IMAGE (0x06) =
    /// [format, bytes]; FIELD_FILE_ATTACHMENTS (0x05) = [[name, bytes], …];
    /// FIELD_ICON_APPEARANCE (0x04); FIELD_REPLY_HASH (0x30) = raw target-hash
    /// bytes + optional FIELD_REPLY_QUOTE (0x31). `extraFields` (pre-encoded raw
    /// bytes, e.g. telemetry/custom-meta) are merged last.
    public static func buildFieldMap(
        imageData: Data?,
        imageFormat: String?,
        fileAttachments: [RnsFileAttachment]?,
        audioAttachment: RnsAudio?,
        iconAppearance: IconAppearance?,
        replyToMessageHashHex: String?,
        replyQuotedContent: String?,
        extraFields: [UInt8: Data]?
    ) -> [UInt8: Any] {
        var fields: [UInt8: Any] = [:]
        if let imageData, let imageFormat {
            fields[LxmfFields.FIELD_IMAGE] = [imageFormat, imageData] as [Any]
        }
        if let fileAttachments, !fileAttachments.isEmpty {
            fields[LxmfFields.FIELD_FILE_ATTACHMENTS] = fileAttachments.map { [$0.name, $0.data] as [Any] }
        }
        if let audioAttachment {
            // FIELD_AUDIO (0x07) = [mode, bytes]. The mode is a plain Int so it
            // encodes as a MessagePack int (matching Android's `[mode, bytes]`).
            fields[LxmfFields.FIELD_AUDIO] = audioAttachment.fieldValue
        }
        if let iconAppearance {
            fields[LxmfFields.FIELD_ICON_APPEARANCE] = iconAppearance.toLXMFFieldValue()
        }
        if let replyToMessageHashHex, let replyHash = try? replyToMessageHashHex.hexToData() {
            fields[LxmfFields.FIELD_REPLY_HASH] = replyHash
            if let replyQuotedContent {
                fields[LxmfFields.FIELD_REPLY_QUOTE] = Data(replyQuotedContent.utf8)
            }
        }
        if let extraFields {
            for (k, v) in extraFields { fields[k] = v }
        }
        return fields
    }

    /// Unpack MessagePack bytes back to an LXMF field map. Returns nil for empty
    /// or malformed data, or if the top level isn't a map.
    public static func unpack(_ data: Data) -> [UInt8: Any]? {
        guard !data.isEmpty, let v = try? unpackMsgPack(data), case .map(let m) = v else { return nil }
        var out: [UInt8: Any] = [:]
        for (k, val) in m {
            guard let key = uint8Key(k) else { continue }
            out[key] = any(from: val)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - [UInt8: Any] → MessagePackValue

    private static func value(fromFieldMap fields: [UInt8: Any]) -> MessagePackValue {
        var m: [MessagePackValue: MessagePackValue] = [:]
        for (k, v) in fields { m[.uint(UInt64(k))] = value(fromAny: v) }
        return .map(m)
    }

    private static func value(fromAny v: Any) -> MessagePackValue {
        switch v {
        case let d as Data:    return .binary(d)
        case let s as String:  return .string(s)
        case let b as Bool:    return .bool(b)
        case let i as Int:     return .int(Int64(i))
        case let i as Int64:   return .int(i)
        case let u as UInt8:   return .uint(UInt64(u))
        case let u as UInt:    return .uint(UInt64(u))
        case let u as UInt64:  return .uint(u)
        case let d as Double:  return .double(d)
        case let f as Float:   return .float(f)
        case let arr as [Any]: return .array(arr.map { value(fromAny: $0) })
        case let dict as [String: Any]:
            var m: [MessagePackValue: MessagePackValue] = [:]
            for (k, val) in dict { m[.string(k)] = value(fromAny: val) }
            return .map(m)
        case let dict as [UInt8: Any]:
            var m: [MessagePackValue: MessagePackValue] = [:]
            for (k, val) in dict { m[.uint(UInt64(k))] = value(fromAny: val) }
            return .map(m)
        default:
            return .nil
        }
    }

    // MARK: - MessagePackValue → Any

    private static func any(from v: MessagePackValue) -> Any {
        switch v {
        case .nil:           return NSNull()
        case .bool(let b):   return b
        case .int(let i):    return Int(truncatingIfNeeded: i)
        case .uint(let u):   return Int(truncatingIfNeeded: u)
        case .float(let f):  return f
        case .double(let d): return d
        case .string(let s): return s
        case .binary(let d): return d
        case .array(let a):  return a.map { any(from: $0) }
        case .map(let m):
            // String-keyed maps (e.g. legacy app_data {"reaction_to":…}) decode to
            // [String: Any]; integer-keyed maps (nested field dicts like the
            // canonical reaction {0x00:…,0x01:…}) decode to [UInt8: Any].
            let allStringKeys = m.keys.allSatisfy { if case .string = $0 { return true } else { return false } }
            if allStringKeys {
                var out: [String: Any] = [:]
                for (k, val) in m { if case .string(let s) = k { out[s] = any(from: val) } }
                return out
            } else {
                var out: [UInt8: Any] = [:]
                for (k, val) in m { if let key = uint8Key(k) { out[key] = any(from: val) } }
                return out
            }
        }
    }

    private static func uint8Key(_ k: MessagePackValue) -> UInt8? {
        switch k {
        case .uint(let u): return UInt8(exactly: u)
        case .int(let i):  return UInt8(exactly: i)
        default:           return nil
        }
    }
}
