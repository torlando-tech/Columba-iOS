//
//  OggOpusWaveform.swift
//  ColumbaApp
//
//  Real-amplitude waveform for Ogg/Opus voice messages (Android parity).
//
//  The bubble's peak bars used to be a flat 0.5 fill for every Ogg message
//  ("decoding the full file for peaks is heavy") - a row of identical short
//  bars. Android decodes the file to PCM and shows a real RMS-per-bucket
//  waveform; this is the iOS equivalent, using AVFoundation's file decoder
//  (AVAudioFile) - the same family of decode as Android's MediaExtractor +
//  MediaCodec, and a decoder that reads these files directly (verified
//  against real artifacts incl. the Sideband HQ file that AVAudioPlayer's
//  render path rejects). No raw opus C dependency is needed.
//
//  Layering (kept apart for testability):
//   - `OggOpusInboundNormalizer.peaksFromEnergy` - PURE bucketing + Android's
//     exact display curve. Unit-tested in CI with synthetic energy (no codec,
//     no I/O, no AVFoundation - so it does not depend on the simulator's
//     Ogg support, which is unreliable).
//   - `peaks(fromBytes:decodeEnergy:)` - PURE orchestration that wires the
//     pre-skip from the metadata parse to `peaksFromEnergy`, with an injected
//     decode. Unit-tested in CI with a synthetic decode closure.
//   - `realWaveform(from:)` - PRODUCTION glue that provides the AVAudioFile
//     decode. Runs on-device (load-bearing); a decode failure is non-fatal and
//     the caller keeps the neutral fallback, so audio still plays.
//

import AVFoundation
import Foundation

/// Decodes Ogg/Opus audio and turns it into the bubble's peak array.
enum OggOpusWaveform {
    /// Bar count matching `VoiceWaveformBars`'s 40-bar geometry.
    static let bars = 40

    /// Pure orchestration: read the pre-skip from the Ogg metadata, run the
    /// injected decode to get per-frame mono energy, and return the normalized
    /// peak array. Returns nil when the injected decode fails or yields no
    /// frames (caller keeps the neutral fallback). `decodeEnergy` is injected
    /// so CI can exercise the curve with synthetic data (the simulator's
    /// AVFoundation is unreliable for Ogg); production uses `realWaveform`.
    static func peaks(
        fromBytes bytes: Data,
        decodeEnergy: (Data) throws -> [Double]
    ) -> [Float]? {
        let preSkip = OggOpusMetadataReader.read([UInt8](bytes))?.preSkip ?? 0
        guard let energy = try? decodeEnergy(bytes), !energy.isEmpty else { return nil }
        return OggOpusInboundNormalizer.peaksFromEnergy(energy, preSkip: preSkip, bars: bars)
    }

    /// Production waveform: decode `bytes` (an in-memory Ogg/Opus file) with
    /// AVFoundation and compute the normalized peak array. Synchronous and
    /// CPU-bound - the player calls this from `prepare` (voice messages are
    /// short; decode is tens of ms). Returns nil on any decode failure, a
    /// file that carries no audio, or a stream that decodes to silence.
    static func realWaveform(from bytes: Data) -> [Float]? {
        peaks(fromBytes: bytes, decodeEnergy: decodeEnergyViaAVAudioFile)
    }

    /// AVAudioFile decode: write the bytes to a temp `.ogg`, decode to mono
    /// PCM, and return per-sample squared energy (channel-folded, linear
    /// float in ~[0,1]). Throws if AVFoundation cannot open/decode the file
    /// or yields no frames.
    private static func decodeEnergyViaAVAudioFile(_ bytes: Data) throws -> [Double] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-waveform", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("waveform-\(UUID().uuidString).ogg")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url)

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)
        else { throw OggWaveformError.noAudio }
        try file.read(into: buffer)

        let n = Int(buffer.frameLength)
        guard n > 0, let channelPtr = buffer.floatChannelData else {
            throw OggWaveformError.noAudio
        }
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount >= 1 else { throw OggWaveformError.noAudio }
        let ch0 = channelPtr[0]

        // Mono-fold: mean of the channels, then squared (energy). Mono voice
        // files fold to themselves.
        var energy = [Double](repeating: 0, count: n)
        if channelCount >= 2 {
            let ch1 = channelPtr[1]
            for i in 0..<n {
                let m = (Double(ch0[i]) + Double(ch1[i])) * 0.5
                energy[i] = m * m
            }
        } else {
            for i in 0..<n {
                let m = Double(ch0[i])
                energy[i] = m * m
            }
        }
        return energy
    }
}

enum OggWaveformError: Error {
    case noAudio
}
