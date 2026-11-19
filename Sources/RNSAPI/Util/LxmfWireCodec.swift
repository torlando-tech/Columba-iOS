//  Copyright (c) 2026 Torlando Tech LLC.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  LxmfWireCodec.swift
//  RNSAPI
//
//  Decode-only LXMF message wire field extractor — the field-recovery subset
//  of the retired torlando-tech/LXMF-swift `LXMessage.unpackFromBytes`
//  (minus all crypto / hash work). Exists solely so `MessageRepository` can
//  recover field maps from legacy rows whose `packed_lxmf` column holds the
//  signed LXMF wire (written by the old Swift / Network-Extension backend)
//  instead of a MessagePack field map.
//
//  Wire layout: dest-hash(16) + source-hash(16) + signature(64) + msgpack
//  payload array `[timestamp, title, content, fields]` (+ optional 5th
//  element, the proof-of-work stamp — ignored here).
//
//  The signature is NOT verified here: the signature verdict belongs to the
//  backend that persisted the row (the Python node records its own
//  `signature_validated` verdict), exactly like Android Columba, which never
//  touches protocol crypto in the app layer. This codec only *extracts* fields.
//

import Foundation

public enum LxmfWireCodec {
    /// dest-hash length (Reticulum Destination.hash).
    private static let destinationLength = 16
    /// signature length (LXMRouter signs with Identity.signingKey).
    private static let signatureLength = 64

    /// Returns the field map if `data` is a valid LXMF message wire
    /// (dest16 + source16 + signature64 + msgpack payload array with a
    /// msgpack-map fields element), else `nil`. A plain field map (top-level
    /// msgpack *map*) fails the array discriminator here — that is the
    /// load-bearing wire-vs-field-map discrimination `MessageRepository`
    /// relies on. Signature is NOT verified; see header.
    public static func fields(fromWire data: Data) -> [UInt8: Any]? {
        // Must have header + some payload (mirrors unpackFromBytes' guard).
        let headerLength = 2 * destinationLength + signatureLength
        guard data.count > headerLength else { return nil }

        let payload = Data(data.dropFirst(headerLength))
        guard let value = try? unpackMsgPack(payload),
              case .array(let payloadArray) = value,
              payloadArray.count >= 4 else { return nil }

        // Strict element-type discriminator (load-bearing — see header):
        // [0] numeric timestamp, [1]/[2] binary-or-string title/content.
        switch payloadArray[0] {
        case .double, .float, .uint, .int: break
        default: return nil
        }
        guard isText(payloadArray[1]), isText(payloadArray[2]) else { return nil }

        // [3] fields: must be a msgpack map (.null / absent → no fields).
        guard case .map(let fieldsMap) = payloadArray[3] else { return nil }

        var fields: [UInt8: Any] = [:]
        for (key, fieldValue) in fieldsMap {
            // Field key: uint (<= 255) or int (0...255); anything else skipped.
            let keyByte: UInt8
            switch key {
            case .uint(let u) where u <= 255:
                keyByte = UInt8(u)
            case .int(let i) where i >= 0 && i <= 255:
                keyByte = UInt8(i)
            default:
                continue
            }
            // Value conversion mirrors LXMFSwift's table exactly so
            // `LxmfFieldCodec.pack` re-packs the map identically.
            switch fieldValue {
            case .binary(let d):
                fields[keyByte] = d
            case .string(let s):
                fields[keyByte] = s
            case .int(let i):
                fields[keyByte] = i
            case .uint(let u):
                // `Int64(u)` traps for uints above Int64.max (malformed/hostile
                // rows); skip those instead — same skip semantics as the other
                // unsupported value types.
                if let asInt = Int64(exactly: u) { fields[keyByte] = asInt }
            case .double(let d):
                fields[keyByte] = d
            case .bool(let b):
                fields[keyByte] = b
            case .array(let array):
                // Flat arrays (Field 0x04 icon appearance) and nested arrays
                // (Field 0x05 file attachments: [[name, data], …]).
                fields[keyByte] = swiftArray(from: array)
            case .map(let nested):
                // String-keyed maps (e.g. legacy app_data) → [String: Any].
                var dict: [String: Any] = [:]
                for (nestedKey, nestedValue) in nested {
                    guard case .string(let name) = nestedKey else { continue }
                    switch nestedValue {
                    case .double(let d): dict[name] = d
                    case .int(let i):    dict[name] = i
                    case .string(let s): dict[name] = s
                    default: break
                    }
                }
                fields[keyByte] = dict
            default:
                break
            }
        }
        return fields.isEmpty ? nil : fields
    }

    private static func isText(_ value: MessagePackValue) -> Bool {
        switch value {
        case .binary, .string: return true
        default: return false
        }
    }

    /// msgpack array → `[Any]` with recursive nested-array support (mirrors
    /// LXMFSwift's `convertMsgpackArrayToSwift`; unsupported element types are
    /// skipped).
    private static func swiftArray(from array: [MessagePackValue]) -> [Any] {
        var result: [Any] = []
        for item in array {
            switch item {
            case .string(let s):   result.append(s)
            case .binary(let d):   result.append(d)
            case .int(let i):      result.append(i)
            case .uint(let u):     result.append(u)
            case .array(let nested): result.append(swiftArray(from: nested))
            default: break
            }
        }
        return result
    }
}
