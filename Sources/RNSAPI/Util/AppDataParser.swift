//
//  AppDataParser.swift
//  RNSAPI
//
//  Decodes the display name out of an LXMF announce's app_data. The Python
//  bridge (`rns_bridge.py`) is intentionally thin — it forwards the raw
//  app_data bytes and lets this layer interpret them, so the LXMF wire-format
//  knowledge lives in one place on the Swift side alongside MsgPack and
//  PropagationNodeInfo.
//
//  app_data layout differs by aspect (see canonical Python LXMF):
//    - lxmf.delivery — LXMRouter.get_announce_app_data:
//        msgpack [display_name_bytes_or_nil, stamp_cost]   → name at index 0
//    - lxmf.propagation — LXMRouter.get_propagation_node_app_data:
//        msgpack [legacy_bool, timebase, node_state, per_transfer_limit,
//                 per_sync_limit, stamp_cost, metadata_map]
//        → index 0 is a LEGACY BOOLEAN (False), NOT the name. The optional
//          name lives in the metadata map at key PN_META_NAME (0x01). Reading
//          index 0 here is what made propagation nodes display as "False".
//

import Foundation

public enum AppDataParser {
    /// LXMF.PN_META_NAME — metadata-map key carrying a propagation node's name.
    static let pnMetaName: UInt64 = 0x01

    /// Best-effort display name from an announce's `appData`, given its aspect.
    /// Returns "" when there's no name (common for propagation nodes) rather
    /// than leaking a non-name field. Never throws — malformed data → "".
    public static func displayName(from appData: Data, aspect: String) -> String {
        guard !appData.isEmpty else { return "" }

        // Propagation node: name (if any) is in the metadata map at index 6.
        if aspect == Aspects.lxmfPropagation {
            guard let value = try? unpackMsgPack(appData),
                  case .array(let arr) = value,
                  arr.count > 6,
                  case .map(let metadata) = arr[6] else { return "" }
            return Self.string(metadata[.uint(pnMetaName)] ?? metadata[.int(Int64(pnMetaName))]) ?? ""
        }

        // Delivery (and other list-shaped app_data): name at index 0.
        if let value = try? unpackMsgPack(appData),
           case .array(let arr) = value,
           let first = arr.first,
           let name = Self.string(first) {
            return name
        }

        // Legacy pre-msgpack clients sent the raw UTF-8 name. Only honored for
        // non-propagation aspects (propagation app_data is always msgpack, so
        // raw-decoding its bytes would produce garbage).
        if aspect != Aspects.lxmfPropagation,
           let raw = String(data: appData, encoding: .utf8) {
            return raw
        }
        return ""
    }

    /// Whether an announced name may replace a conversation's current name.
    ///
    /// Inbound messages can create a conversation before its peer announce is
    /// observed. That row receives the generated `Peer <hash>` placeholder, so
    /// treating every non-empty name as user-owned leaves the placeholder stuck
    /// forever. Replace only an empty value or the exact generated placeholder;
    /// preserve custom nicknames and unrelated peer-like names.
    public static func shouldReplaceConversationName(
        _ existingName: String?,
        destinationHash: Data
    ) -> Bool {
        guard let existingName, !existingName.isEmpty else { return true }
        let generatedFallback = generatedConversationName(destinationHash: destinationHash)
        return existingName.caseInsensitiveCompare(generatedFallback) == .orderedSame
    }

    /// The placeholder used when a message arrives before its peer announce.
    public static func generatedConversationName(destinationHash: Data) -> String {
        let hashPrefix = destinationHash.prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        return "Peer \(hashPrefix)"
    }

    /// Pull a UTF-8 string out of a `.string` or `.binary` MessagePackValue.
    /// `.nil` / other cases → nil (so callers can fall back to "").
    private static func string(_ value: MessagePackValue?) -> String? {
        switch value {
        case .string(let s): return s
        case .binary(let d): return String(data: d, encoding: .utf8)
        default: return nil
        }
    }
}
