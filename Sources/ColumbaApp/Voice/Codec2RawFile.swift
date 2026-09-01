//
//  Codec2RawFile.swift
//  ColumbaApp
//
//  Codec2 voice-message file codec. The on-disk / on-wire Codec2 payload is a
//  RAW concatenation of complete Codec2 frames — NO telephone profile/mode
//  header byte and NO Ogg wrap (the mode is carried in the `FIELD_AUDIO`
//  `[mode, bytes]` tuple, not in the payload). This matches Android Columba's
//  `Codec2VoiceRecorderBackend`, which writes each frame's bytes straight to
//  the `.c2` file with no header, and Python LXST / Sideband, which decode the
//  raw frames given the mode.
//
//  LXSTSwift's `Codec2Codec.encode` PREPENDS a mode-header byte and
//  `decode` EXPECTS one — so we strip the header byte on write and prefix it
//  (the `AudioMode.codec2HeaderByte` = `Codec2Mode.rawValue`, a DIFFERENT
//  numbering from the wire mode) on decode. The header byte is never stored in
//  the file or sent on the wire.
//

import Foundation
import LXSTSwift

/// Decoded Codec2 PCM (8 kHz mono int16).
public struct DecodedCodec2 {
    public let samples: [Int16]
    public let sampleRateHz: Int
    public var durationMs: Int { (samples.count * 1_000) / sampleRateHz }
}

public enum Codec2FileError: Error, Equatable {
    case incompleteFrame          // payload is not a whole number of frames
    case noFrames                 // payload is empty
    case exceedsDecodeCeiling     // would exceed the 5-minute decoded-sample ceiling
    case emptyPcm
}

public enum Codec2RawFile {

    /// Codec2 fixed input/output rate (all modes).
    public static let sampleRate = 8_000
    /// 5-minute decoded-sample ceiling (matches Android's `MAX_DECODED_SAMPLES`
    /// = INPUT_RATE * 60 * 5). Checked in WIDE arithmetic before allocating the
    /// decoded buffer, so a small hostile payload cannot expand into unbounded
    /// decoded memory.
    public static let maxDecodedSamples: Int = sampleRate * 60 * 5

    // MARK: - Encode (for the recorder)

    /// Encode one full Codec2 frame of PCM and return its RAW frame bytes
    /// (the leading mode-header byte that LXSTSwift prepends is stripped).
    ///
    /// - Parameters:
    ///   - pcm: exactly `samplesPerFrame` mono int16 samples at 8 kHz.
    ///   - codec: the `Codec2Codec` for the selected mode.
    @discardableResult
    public static func encodeFrame(
        pcm: [Int16],
        codec: Codec2Codec
    ) throws -> Data {
        guard !pcm.isEmpty else { throw Codec2FileError.emptyPcm }
        let encoded = try codec.encode(pcm)
        // Strip the leading mode-header byte LXSTSwift prepends.
        return encoded.count > 1 ? Data(encoded.dropFirst()) : Data()
    }

    /// Encode a whole PCM buffer to the raw frame concatenation (header byte
    /// stripped). Equivalent to encoding frame-by-frame and concatenating, but
    /// a single call into LXSTSwift.
    public static func encodeAll(
        pcm: [Int16],
        codec: Codec2Codec
    ) throws -> Data {
        guard !pcm.isEmpty else { throw Codec2FileError.emptyPcm }
        let encoded = try codec.encode(pcm)
        return encoded.count > 1 ? Data(encoded.dropFirst()) : Data()
    }

    // MARK: - Decode (for playback / metadata)

    /// Decode a raw Codec2 frame concatenation back to 8 kHz mono PCM.
    ///
    /// The mode (from `AudioMode`) supplies the header byte that LXSTSwift's
    /// decoder expects as the first byte; the header is prefixed here and never
    /// present in the file/wire payload. Enforces the 5-minute decoded ceiling
    /// before allocating.
    public static func decode(
        _ bytes: Data,
        mode: AudioMode,
        codec: Codec2Codec
    ) throws -> DecodedCodec2 {
        guard bytes.count > 0 else { throw Codec2FileError.noFrames }
        guard let c2 = mode.codec2Mode else { throw Codec2FileError.noFrames } // not a Codec2 mode
        guard let header = mode.codec2HeaderByte else { throw Codec2FileError.noFrames }
        let geometry = geometry(for: c2)
        guard geometry.bytesPerFrame > 0 else { throw Codec2FileError.incompleteFrame }
        let frameCount = bytes.count / geometry.bytesPerFrame
        guard frameCount > 0 else { throw Codec2FileError.incompleteFrame }
        guard bytes.count % geometry.bytesPerFrame == 0 else { throw Codec2FileError.incompleteFrame }
        // Wide-arithmetic ceiling check BEFORE allocating the output buffer.
        let sampleCount = Int64(frameCount) * Int64(geometry.samplesPerFrame)
        guard sampleCount <= Int64(maxDecodedSamples) else {
            throw Codec2FileError.exceedsDecodeCeiling
        }
        let framed = Data([header]) + bytes
        let samples = try codec.decode(framed)
        return DecodedCodec2(samples: samples, sampleRateHz: sampleRate)
    }

    /// Convenience decode that constructs the codec from the mode (for the
    /// playback / waveform / metadata paths, which only know the `AudioMode`).
    @discardableResult
    public static func decodePayload(
        _ bytes: Data,
        mode: AudioMode
    ) throws -> DecodedCodec2 {
        guard let c2 = mode.codec2Mode else { throw Codec2FileError.noFrames }
        let codec = try Codec2Codec(mode: c2)
        return try decode(bytes, mode: mode, codec: codec)
    }

    // MARK: - WAV bridge (for AVAudioPlayer)

    /// Write decoded 8 kHz mono PCM16 to a WAV file (RIFF/WAVE). `AVAudioPlayer`
    /// plays WAV; it cannot play raw Codec2 frames.
    @discardableResult
    public static func writeWave(_ decoded: DecodedCodec2, to url: URL) throws -> URL {
        let sampleRate = decoded.sampleRateHz
        let pcm = decoded.samples
        let pcmByteCount = pcm.count * 2
        var wav = Data(capacity: 44 + pcmByteCount)
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: withLE32(36 + pcmByteCount))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: withLE32(16))     // fmt chunk size
        wav.append(contentsOf: withLE16(1))      // PCM format
        wav.append(contentsOf: withLE16(1))      // mono
        wav.append(contentsOf: withLE32(sampleRate))
        wav.append(contentsOf: withLE32(sampleRate * 2)) // byte rate
        wav.append(contentsOf: withLE16(2))      // block align
        wav.append(contentsOf: withLE16(16))     // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: withLE32(pcmByteCount))
        for s in pcm {
            wav.append(UInt8(s & 0xFF))
            wav.append(UInt8((s >> 8) & 0xFF))
        }
        try wav.write(to: url)
        return url
    }

    // MARK: - Codec geometry (static; LXSTSwift keeps samplesPerFrame/bytesPerFrame
    // private, so we use the authoritative libcodec2 table. `bytesPerFrame` is
    // self-consistent as bitrate × samplesPerFrame / 8000.)

    /// (samplesPerFrame, bytesPerFrame) per Codec2 mode.
    public static func geometry(for mode: Codec2Mode) -> (samplesPerFrame: Int, bytesPerFrame: Int) {
        switch mode {
        case .codec2_700C:  return (160, 14)
        case .codec2_1200:  return (240, 36)
        case .codec2_1300:  return (240, 39)
        case .codec2_1400:  return (240, 42)
        case .codec2_1600:  return (240, 48)
        case .codec2_2400:  return (320, 96)
        case .codec2_3200:  return (320, 128)
        }
    }

    // MARK: - Endianness

    private static func withLE16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func withLE32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
