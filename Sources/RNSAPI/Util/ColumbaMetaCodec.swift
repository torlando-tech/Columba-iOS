//
//  ColumbaMetaCodec.swift
//  RNSAPI
//
//  Codec for Columba's `FIELD_CUSTOM_META` (0xFD) payload — the location-share
//  extras (`cease`, `expires`, `approxRadius`, ms-precision `ts`) that ride
//  alongside a Sideband `Telemeter` blob (`FIELD_TELEMETRY` 0x02).
//
//  iOS analog of Android `rns-api`'s `TelemeterCodec.packColumbaMeta` /
//  `unpackColumbaMeta`. The wire form is **msgpack** `{cease?, expires?,
//  approxRadius?, ts?}` — NOT JSON. Android decodes this field with a
//  MessagePack unpacker; a JSON byte string (`{"cease": true}`) parses there as
//  a bare positive-fixint (the leading `{` byte = 0x7B = 123), so the map is
//  never seen and the cease is silently dropped. iOS historically packed it as
//  JSON, which is exactly that interop break — this codec is the fix.
//

import Foundation

public enum ColumbaMetaCodec {
    /// Decoded Columba extras. Mirror of Android's `TelemeterCodec.ColumbaMeta`.
    public struct Meta: Equatable, Sendable {
        public let cease: Bool
        public let expires: Int64?
        public let approxRadius: Int
        /// ms-precision timestamp the sender carried alongside the
        /// seconds-precision Telemeter `last_update`; nil when absent.
        public let tsMillis: Int64?

        public init(cease: Bool = false, expires: Int64? = nil, approxRadius: Int = 0, tsMillis: Int64? = nil) {
            self.cease = cease
            self.expires = expires
            self.approxRadius = approxRadius
            self.tsMillis = tsMillis
        }
    }

    /// Pack the Columba extras as msgpack, or `nil` when there is nothing worth
    /// sending (no cease / expiry / coarsening radius / sub-second ts) — the
    /// caller should then OMIT `FIELD_CUSTOM_META` so Sideband peers see a clean
    /// Telemeter-only payload. Matches Android's `packColumbaMeta`.
    public static func pack(_ meta: Meta) -> Data? {
        var pairs: [(MessagePackValue, MessagePackValue)] = []
        if meta.cease { pairs.append((.string("cease"), .bool(true))) }
        if let expires = meta.expires { pairs.append((.string("expires"), .int(expires))) }
        if meta.approxRadius > 0 { pairs.append((.string("approxRadius"), .int(Int64(meta.approxRadius)))) }
        // ms-precision ts is worth carrying only when it's NOT a clean second
        // boundary (Telemeter's last_update quantizes to seconds) — matches
        // Android so the two codecs emit byte-identical meta.
        if let ts = meta.tsMillis, ts % 1000 != 0 { pairs.append((.string("ts"), .int(ts))) }
        guard !pairs.isEmpty else { return nil }
        return packMsgPack(.map(Dictionary(uniqueKeysWithValues: pairs)))
    }

    /// The canonical stop-sharing payload: msgpack `{"cease": true}`.
    /// Non-nil by construction (the cease flag is always set).
    public static func packCease() -> Data {
        pack(Meta(cease: true)) ?? packMsgPack(.map([.string("cease"): .bool(true)]))
    }

    /// Unpack a `FIELD_CUSTOM_META` blob. Returns `nil` when the bytes aren't a
    /// msgpack map (e.g. a malformed peer payload). Mirror of `unpackColumbaMeta`.
    public static func unpack(_ data: Data) -> Meta? {
        guard let value = try? unpackMsgPack(data), case .map(let m) = value else { return nil }
        func intValue(_ key: String) -> Int64? {
            switch m[.string(key)] {
            case .int(let n): return n
            case .uint(let n): return Int64(exactly: n)
            default: return nil
            }
        }
        let cease: Bool
        if case .bool(let b) = m[.string("cease")] { cease = b } else { cease = false }
        return Meta(
            cease: cease,
            expires: intValue("expires"),
            approxRadius: intValue("approxRadius").map(Int.init) ?? 0,
            tsMillis: intValue("ts")
        )
    }
}
