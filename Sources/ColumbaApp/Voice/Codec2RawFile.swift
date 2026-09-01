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
        guard mode.codec2Mode != nil, let header = mode.codec2HeaderByte else {
            throw Codec2FileError.noFrames // not a Codec2 mode
        }
        let geometry = geometry(of: codec)
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

    // MARK: - Codec geometry (derived from the LIVE codec)
    //
    // Android reads samplesPerFrame/bytesPerFrame straight from the native
    // handle (NativeCodec2.getSamplesPerFrame/getFrameBytes). LXSTSwift reads
    // the same live values at init but keeps them `private`, and it is a remote
    // SPM dependency we do not fork. So we DERIVE the geometry from the codec
    // itself: samplesPerFrame is the smallest PCM length that encodes to one
    // frame (encode() throws below that), and bytesPerFrame is that one frame's
    // byte count (minus the prepended mode-header byte). Result is cached per
    // mode (keyed by the mode header byte). This guarantees the geometry always
    // matches what the linked libcodec2 actually produces - no hardcoded table
    // to drift. (An earlier hardcoded table computed bytesPerFrame in BITS,
    // which was 8x too large and broke every Codec2 encode/decode assertion.)

    private static let geoLock = NSLock()
    private static var geoCache: [UInt8: (samplesPerFrame: Int, bytesPerFrame: Int)] = [:]

    /// Geometry for a codec already in the requested mode (preferred: avoids
    /// building a second codec instance).
    public static func geometry(of codec: Codec2Codec) -> (samplesPerFrame: Int, bytesPerFrame: Int) {
        let key = codec.modeHeader
        geoLock.lock()
        if let cached = geoCache[key] { geoLock.unlock(); return cached }
        geoLock.unlock()
        let derived = probeGeometry(codec)
        geoLock.lock(); geoCache[key] = derived; geoLock.unlock()
        return derived
    }

    /// Geometry for a mode (convenience: builds a codec, then derives).
    public static func geometry(for mode: Codec2Mode) -> (samplesPerFrame: Int, bytesPerFrame: Int) {
        let key = UInt8(mode.rawValue)
        geoLock.lock()
        if let cached = geoCache[key] { geoLock.unlock(); return cached }
        geoLock.unlock()
        guard let codec = try? Codec2Codec(mode: mode) else {
            return (0, 0) // fail closed: callers guard bytesPerFrame > 0
        }
        let derived = probeGeometry(codec)
        geoLock.lock(); geoCache[key] = derived; geoLock.unlock()
        return derived
    }

    /// Find (samplesPerFrame, bytesPerFrame) by probing the live codec.
    /// `encode(N)` throws exactly when N < samplesPerFrame (fewer than one
    /// frame), so binary-searching the success boundary yields samplesPerFrame.
    /// Then encode exactly that many samples and measure the frame's byte count
    /// (minus the leading mode-header byte LXSTSwift prepends).
    private static func probeGeometry(_ codec: Codec2Codec) -> (samplesPerFrame: Int, bytesPerFrame: Int) {
        guard (try? codec.encode(probePCM(4096))) != nil else { return (0, 0) }
        var lo = 1, hi = 4096
        while lo < hi {
            let mid = (lo + hi) / 2
            if (try? codec.encode(probePCM(mid))) != nil { hi = mid } else { lo = mid + 1 }
        }
        let spf = lo
        guard let full = try? codec.encode(probePCM(spf)), full.count > 1 else { return (0, 0) }
        return (spf, full.count - 1) // drop the leading mode-header byte
    }

    /// Deterministic probe PCM (content is irrelevant; encode only cares about
    /// the sample count relative to samplesPerFrame).
    private static func probePCM(_ n: Int) -> [Int16] {
        var a = [Int16](repeating: 0, count: n)
        for i in 0..<n { a[i] = Int16((i * 37) % 2000 - 1000) }
        return a
    }

    // MARK: - Endianness

    private static func withLE16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func withLE32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
