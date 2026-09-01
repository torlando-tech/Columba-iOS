//
//  LxmfFields.swift
//  RNSAPI
//
//  LXMF protocol field IDs Columba reads or writes — the single source of truth
//  for both backends (Python-flavor + Swift-native) and the UI. Mirrors Android
//  Columba's `rns-api/util/LxmfFields.kt` so the two platforms stay in sync.
//
//  Numeric values are the upstream LXMF spec (`LXMF/LXMF.py`). Only fields
//  Columba actually uses on the wire are listed.
//
//  ⚠️ Interop note: Columba-iOS historically used divergent values that did NOT
//  match upstream/Sideband/Android —
//    • telemetry on 0x08 (upstream 0x08 is FIELD_THREAD; Sideband reads telemetry
//      at FIELD_TELEMETRY = 0x02), so iOS telemetry never interoperated; and
//    • app-meta on an invented 0x70 (Android migrated this to the upstream
//      canonical FIELD_CUSTOM_META = 0xFD).
//  These constants are the corrected, Sideband-compatible values.
//

import Foundation

public enum LxmfFields {

    /// LXMF app name for delivery destinations (`LXMF.LXMRouter.APP_NAME`).
    public static let APP_NAME = "lxmf"
    /// Local aspect for LXMF delivery destinations (`LXMRouter.DELIVERY_ASPECT`).
    public static let DELIVERY_ASPECT = "delivery"

    /// Single-shot telemetry payload (Sideband-compatible packed location).
    public static let FIELD_TELEMETRY: UInt8 = 0x02
    /// Multi-entry telemetry stream — propagation collector responses.
    public static let FIELD_TELEMETRY_STREAM: UInt8 = 0x03
    /// `[name, fgRgbBytes, bgRgbBytes]` — Sideband/MeshChat icon appearance.
    public static let FIELD_ICON_APPEARANCE: UInt8 = 0x04
    /// Sideband-compatible file attachments — `[[name, bytes], ...]`.
    public static let FIELD_FILE_ATTACHMENTS: UInt8 = 0x05
    /// Image payload — `[format, bytes]`.
    public static let FIELD_IMAGE: UInt8 = 0x06
    /// Audio payload — `[mode, bytes]`.
    public static let FIELD_AUDIO: UInt8 = 0x07
    /// Command structures (Sideband telemetry-request RPCs).
    public static let FIELD_COMMANDS: UInt8 = 0x09
    /// Optional content renderer indication from upstream LXMF.
    public static let FIELD_RENDERER: UInt8 = 0x0F
    public static let RENDERER_PLAIN = 0x00
    public static let RENDERER_MICRON = 0x01
    public static let RENDERER_MARKDOWN = 0x02
    public static let RENDERER_BBCODE = 0x03

    /// Canonical tap-back reaction — `fields[0x40] = {0x00: targetHashBytes,
    /// 0x01: emojiUTF8Bytes}` (standardised upstream in LXMF.py). The reacting
    /// user is derived from the inbound source hash, not carried on the wire.
    public static let FIELD_REACTION: UInt8 = 0x40
    /// `FIELD_REACTION` dict key — raw bytes of the target `LXMessage.hash`.
    public static let REACTION_TO: UInt8 = 0x00
    /// `FIELD_REACTION` dict key — UTF-8 bytes of the reaction content (emoji).
    public static let REACTION_CONTENT: UInt8 = 0x01
    /// Legacy reaction `fields[0x10] = {reaction_to, emoji, sender}` — parse-only
    /// fallback for un-upgraded peers; outbound uses `FIELD_REACTION` (0x40).
    public static let FIELD_REACTION_LEGACY: UInt8 = 0x10

    /// Reply-target message hash — `fields[0x30] = Data` (32 raw bytes, not hex).
    public static let FIELD_REPLY_HASH: UInt8 = 0x30
    /// Optional reply quoted content — `fields[0x31] = Data` (UTF-8 of the
    /// original content, so the recipient can render a preview without the
    /// original in their local store).
    public static let FIELD_REPLY_QUOTE: UInt8 = 0x31

    /// Upstream LXMF `FIELD_CUSTOM_META` (0xFD) — documented extension point for
    /// app-specific metadata other LXMF clients ignore. Columba carries the
    /// `cease` / `expires` / `approxRadius` extras that ride alongside a
    /// Sideband-compatible `FIELD_TELEMETRY` location share here. (Replaces the
    /// previously-invented 0x70, matching Android's migration.)
    public static let FIELD_CUSTOM_META: UInt8 = 0xFD

    // MARK: - FIELD_AUDIO mode values
    //
    // `FIELD_AUDIO` (0x07) is `[mode, bytes]`. `mode` is one of the upstream
    // LXMF audio-mode constants below. These WIRE values are defined by
    // upstream LXMF (`LXMF/LXMF.py`), match Android Columba's `LxmfFields`, and
    // are the values Sideband/MeshChatX read. NOTE they are a DIFFERENT
    // numbering scheme from the LXST `Codec2Mode` header byte (700C=0x00,
    // 1200=0x01, … 3200=0x06) — map by bitrate, never by raw value. See
    // `AudioMode.codec2Mode` in ColumbaApp.

    /// Codec2 450 PWB — not offered by Columba's picker; parse-only.
    public static let AM_CODEC2_450PWB: UInt8 = 0x01
    /// Codec2 450 — not offered by Columba's picker; parse-only.
    public static let AM_CODEC2_450: UInt8 = 0x02
    /// Codec2 700C.
    public static let AM_CODEC2_700C: UInt8 = 0x03
    /// Codec2 1200.
    public static let AM_CODEC2_1200: UInt8 = 0x04
    /// Codec2 1300 — not offered by Columba's picker; parse-only.
    public static let AM_CODEC2_1300: UInt8 = 0x05
    /// Codec2 1400 — not offered by Columba's picker; parse-only.
    public static let AM_CODEC2_1400: UInt8 = 0x06
    /// Codec2 1600 — not offered by Columba's picker; parse-only.
    public static let AM_CODEC2_1600: UInt8 = 0x07
    /// Codec2 2400.
    public static let AM_CODEC2_2400: UInt8 = 0x08
    /// Codec2 3200.
    public static let AM_CODEC2_3200: UInt8 = 0x09
    /// Ogg/Opus (the only Opus mode Columba emits; stored as an Ogg file).
    public static let AM_OPUS_OGG: UInt8 = 0x10
    /// Custom / unspecified audio mode (the client must self-describe).
    public static let AM_CUSTOM: UInt8 = 0xFF
}

/// The message-body presentation Columba currently supports.
///
/// Unsupported, absent, and malformed renderer indications deliberately fail
/// closed to plaintext. Markdown is selected only by an integer wire value 2.
public enum MessageRenderer: Equatable, Sendable {
    case plain
    case markdown

    public init(fields: [UInt8: Any]?) {
        guard let rawValue = fields?[LxmfFields.FIELD_RENDERER] else {
            self = .plain
            return
        }

        let rendererValue: UInt64?
        switch rawValue {
        case let value as Int where value >= 0:
            rendererValue = UInt64(value)
        case let value as Int8 where value >= 0:
            rendererValue = UInt64(value)
        case let value as Int16 where value >= 0:
            rendererValue = UInt64(value)
        case let value as Int32 where value >= 0:
            rendererValue = UInt64(value)
        case let value as Int64 where value >= 0:
            rendererValue = UInt64(value)
        case let value as UInt:
            rendererValue = UInt64(value)
        case let value as UInt8:
            rendererValue = UInt64(value)
        case let value as UInt16:
            rendererValue = UInt64(value)
        case let value as UInt32:
            rendererValue = UInt64(value)
        case let value as UInt64:
            rendererValue = value
        default:
            rendererValue = nil
        }

        self = rendererValue == UInt64(LxmfFields.RENDERER_MARKDOWN)
            ? .markdown
            : .plain
    }
}
