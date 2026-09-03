//
//  AudioMode.swift
//  ColumbaApp
//
//  The canonical audio-mode values used in LXMF `FIELD_AUDIO` (0x07) =
//  `[mode, bytes]`. These mirror the wire constants in RNSAPI's
//  `LxmfFields.AM_*` (which match upstream LXMF and Android), and add the
//  mapping between that WIRE numbering and the LXST `Codec2Mode` header-byte
//  numbering, which are DIFFERENT schemes and must never be conflated.
//

import Foundation
import RNSAPI
import LXSTSwift

/// A canonical LXMF `FIELD_AUDIO` mode.
///
/// The raw value is the on-wire integer (see `LxmfFields.AM_*`). Codec2 modes
/// carry their bitrate so the two numbering schemes (wire mode vs LXST
/// `Codec2Mode` header byte) can be reconciled by bitrate rather than raw
/// value:
///
///   | mode             | wire | Codec2Mode header |
///   | ---------------- | ---- | ----------------- |
///   | codec2 700C      | 0x03 | 0x00              |
///   | codec2 1200      | 0x04 | 0x01              |
///   | codec2 1300      | 0x05 | 0x02              |
///   | codec2 1400      | 0x06 | 0x03              |
///   | codec2 1600      | 0x07 | 0x04              |
///   | codec2 2400      | 0x08 | 0x05              |
///   | codec2 3200      | 0x09 | 0x06              |
///   | opus (ogg)       | 0x10 | -                 |
///   | custom           | 0xFF | -                 |
public enum AudioMode: UInt8, Equatable, Hashable, Sendable {
    case codec2_450PWB = 0x01
    case codec2_450 = 0x02
    case codec2_700C = 0x03
    case codec2_1200 = 0x04
    case codec2_1300 = 0x05
    case codec2_1400 = 0x06
    case codec2_1600 = 0x07
    case codec2_2400 = 0x08
    case codec2_3200 = 0x09
    case opusOgg = 0x10
    case custom = 0xFF

    /// True for every Codec2 mode (the payload is a raw Codec2 frame
    /// concatenation, not an Ogg file).
    public var isCodec2: Bool {
        switch self {
        case .codec2_450PWB, .codec2_450, .codec2_700C, .codec2_1200,
             .codec2_1300, .codec2_1400, .codec2_1600, .codec2_2400,
             .codec2_3200:
            return true
        case .opusOgg, .custom:
            return false
        }
    }

    /// The Codec2 bitrate (bps) for Codec2 modes, else nil.
    public var codec2Bitrate: Int? {
        switch self {
        case .codec2_450PWB: return 450
        case .codec2_450: return 450
        case .codec2_700C: return 700
        case .codec2_1200: return 1200
        case .codec2_1300: return 1300
        case .codec2_1400: return 1400
        case .codec2_1600: return 1600
        case .codec2_2400: return 2400
        case .codec2_3200: return 3200
        case .opusOgg, .custom: return nil
        }
    }

    /// The LXST `Codec2Mode` (header-byte numbering) this wire mode maps to,
    /// resolved by bitrate. nil for non-Codec2 modes and for Codec2 rates
    /// LXST does not implement (450/450PWB are not in LXST `Codec2Mode`).
    public var codec2Mode: Codec2Mode? {
        switch self {
        case .codec2_700C: return .codec2_700C
        case .codec2_1200: return .codec2_1200
        case .codec2_1300: return .codec2_1300
        case .codec2_1400: return .codec2_1400
        case .codec2_1600: return .codec2_1600
        case .codec2_2400: return .codec2_2400
        case .codec2_3200: return .codec2_3200
        case .opusOgg, .custom, .codec2_450PWB, .codec2_450: return nil
        }
    }

    /// The single-byte Codec2 header value (LXST `Codec2Mode.rawValue`) that
    /// must PREFIX the raw frames when decoding, and that LXST `encode`
    /// prepends and we strip when writing. nil for non-Codec2 modes.
    public var codec2HeaderByte: UInt8? { codec2Mode?.rawValue }

    /// Build an `AudioMode` from an on-wire integer, accepting any canonical
    /// value. Unknown / non-canonical bytes map to `.custom` so a message with
    /// an unrecognized mode still renders (as non-playable) instead of being
    /// dropped.
    public init?(wireValue: Int) {
        guard let raw = UInt8(exactly: UInt64(wireValue & 0xFF)) else { return nil }
        // Accept only canonical values; anything else is `.custom`.
        switch raw {
        case 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x10, 0xFF:
            self = AudioMode(rawValue: raw)!
        default:
            self = .custom
        }
    }
}

/// A stored voice-message attachment, decoded from `FIELD_AUDIO`
/// (`[mode, bytes]`) or produced by the recorder before send.
///
/// The payload encoding is dictated by `mode`:
///   - Codec2 modes: raw concatenation of complete Codec2 frames (NO header
///     byte; the mode is known from `mode`, not from a header byte).
///   - `.opusOgg`: a valid Ogg/Opus file (the `bytes` ARE the `.ogg`).
public struct AudioAttachment: Equatable, Sendable {
    public let mode: AudioMode
    public let bytes: Data
    /// Decoded duration in milliseconds (best-effort; nil if not yet computed).
    public var durationMs: Int?
    public var sizeBytes: Int

    public init(mode: AudioMode, bytes: Data, durationMs: Int? = nil) {
        self.mode = mode
        self.bytes = bytes
        self.durationMs = durationMs
        self.sizeBytes = bytes.count
    }

    /// Decoded duration in seconds (best-effort; 0 when not yet computed).
    public var durationSeconds: Double {
        guard let ms = durationMs, ms > 0 else { return 0 }
        return Double(ms) / 1000.0
    }

    /// The `FIELD_AUDIO` wire value: `[mode, bytes]`.
    public var fieldValue: [Any] { [mode.rawValue, bytes] }

    /// Extract an `AudioAttachment` from a decoded `FIELD_AUDIO` value
    /// (`[Int, Data]`). Accepts the canonical array form leniently: the mode
    /// may arrive as any signed/unsigned integer and the payload must be
    /// `Data`. Returns nil when the shape is not recognized (the caller then
    /// renders a non-playable "unsupported voice message" bubble).
    public static func fromWireValue(_ value: Any?) -> AudioAttachment? {
        guard let arr = value as? [Any], arr.count >= 2 else { return nil }
        // The mode is the first element; accept it as any integer type.
        let modeValue: Int
        switch arr[0] {
        case let i as Int: modeValue = i
        case let i as Int8: modeValue = Int(i)
        case let i as Int16: modeValue = Int(i)
        case let i as Int32: modeValue = Int(i)
        case let i as Int64: modeValue = Int(i)
        case let u as UInt8: modeValue = Int(u)
        case let u as UInt16: modeValue = Int(u)
        case let u as UInt32: modeValue = Int(u)
        case let u as UInt64: modeValue = Int(u)
        default: return nil
        }
        guard let mode = AudioMode(wireValue: modeValue) else { return nil }
        guard let data = arr[1] as? Data else { return nil }
        return AudioAttachment(mode: mode, bytes: data)
    }
}
