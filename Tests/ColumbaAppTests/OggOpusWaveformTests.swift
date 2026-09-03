//
//  OggOpusWaveformTests.swift
//  ColumbaAppTests
//
//  The real-amplitude waveform path (Android parity):
//   - `peaksFromEnergy` is PURE (synthetic energy in, no codec / no AVFoundation)
//     so it runs identically on the simulator CI and pins Android's exact
//     display curve: per-bucket RMS normalized to
//     `0.12 + 0.88 * (rms/peak)^0.7`, clamped to [0.12, 1].
//   - `peaks(fromBytes:decodeEnergy:)` is pure orchestration with an injected
//     decode, so CI pins the fail-open contract (decode failure or no audio
//     -> nil, caller keeps the neutral placeholder).
//   - `realWaveform` (the AVAudioFile glue) is verified on-device, not here:
//     the simulator's AVFoundation is unreliable for Ogg, exactly why the
//     player treats decode failure as non-fatal.
//

import Foundation
import XCTest
import LXSTSwift
@testable import ColumbaApp

final class OggOpusWaveformTests: XCTestCase {

    // MARK: - peaksFromEnergy (pure curve)

    func testConstantEnergyIsFlatAtFullHeight() {
        let energy = [Double](repeating: 0.25, count: 4_000)
        let peaks = OggOpusInboundNormalizer.peaksFromEnergy(energy, preSkip: 0, bars: 40)
        XCTAssertEqual(peaks.count, 40)
        // Every bucket has the same RMS; the peak bucket normalizes to 1.0.
        for p in peaks {
            XCTAssertEqual(p, 1.0, accuracy: 0.0001)
        }
    }

    func testLoudestBucketIsOneSilentBucketsAreMinLevel() {
        // 40 buckets of 100 frames: all silence except bucket 10 (amplitude 1).
        var energy = [Double](repeating: 0, count: 4_000)
        for i in (10 * 100)..<(11 * 100) { energy[i] = 1.0 }
        let peaks = OggOpusInboundNormalizer.peaksFromEnergy(energy, preSkip: 0, bars: 40)
        XCTAssertEqual(peaks[10], 1.0, accuracy: 0.0001)
        for (index, p) in peaks.enumerated() where index != 10 {
            XCTAssertEqual(p, 0.12, accuracy: 0.0001, "bucket \(index)")
        }
    }

    func testShapeTracksVolumeRamp() {
        // Amplitude ramps linearly 0 -> 1 over the stream: the last bar must
        // be the loudest and strictly above the first.
        let n = 4_000
        var energy = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = Double(i) / Double(n - 1)
            energy[i] = a * a
        }
        let peaks = OggOpusInboundNormalizer.peaksFromEnergy(energy, preSkip: 0, bars: 40)
        XCTAssertEqual(peaks.max() ?? 0, 1.0, accuracy: 0.0001)
        let argmax = peaks.indices.max { peaks[$0] < peaks[$1] }!
        XCTAssertEqual(argmax, 39)
        XCTAssertGreaterThan(peaks[39], peaks[0])
        // All bars stay within the display band.
        for p in peaks {
            XCTAssertGreaterThanOrEqual(p, 0.12)
            XCTAssertLessThanOrEqual(p, 1.0)
        }
    }

    func testPreSkipTrimsEncoderDelay() {
        // Silence for the first 400 frames (the delay), then constant tone.
        // With preSkip = 400 the whole visible stream is the tone -> flat 1.0;
        // with preSkip = 0 the leading silence pulls the first buckets down.
        var energy = [Double](repeating: 0, count: 4_400)
        for i in 400..<4_400 { energy[i] = 0.25 }
        let trimmed = OggOpusInboundNormalizer.peaksFromEnergy(energy, preSkip: 400, bars: 40)
        let untrimmed = OggOpusInboundNormalizer.peaksFromEnergy(energy, preSkip: 0, bars: 40)
        for p in trimmed { XCTAssertEqual(p, 1.0, accuracy: 0.0001) }
        XCTAssertLessThan(untrimmed[0], 1.0)
        // The trimmed timeline is strictly no lower anywhere.
        for i in 0..<40 { XCTAssertGreaterThanOrEqual(trimmed[i], untrimmed[i] - 0.0001) }
    }

    func testEmptyAndDegenerateInputs() {
        XCTAssertEqual(
            OggOpusInboundNormalizer.peaksFromEnergy([], preSkip: 0, bars: 40).count, 0)
        // preSkip past the end: all buckets empty -> flat min level.
        let allMin = OggOpusInboundNormalizer.peaksFromEnergy(
            [Double](repeating: 0.5, count: 100), preSkip: 1_000, bars: 40)
        XCTAssertEqual(allMin.count, 40)
        for p in allMin { XCTAssertEqual(p, 0.12, accuracy: 0.0001) }
        // All-silence: flat min level.
        let silent = OggOpusInboundNormalizer.peaksFromEnergy(
            [Double](repeating: 0, count: 1_000), preSkip: 0, bars: 40)
        for p in silent { XCTAssertEqual(p, 0.12, accuracy: 0.0001) }
    }

    // MARK: - peaks(fromBytes:decodeEnergy:) (injected-decode orchestration)

    func testInjectedDecodeYieldsNormalizedPeaks() {
        let bytes = Data([0x01, 0x02, 0x03])
        let energy: [Double] = (0..<4_000).map { i in
            let a = 0.1 + 0.9 * (sin(Double(i) / 200) * 0.5 + 0.5)
            return a * a
        }
        let peaks = OggOpusWaveform.peaks(
            fromBytes: bytes) { _ in energy }
        XCTAssertEqual(peaks?.count, OggOpusWaveform.bars)
        guard let peaks else { return XCTFail("expected peaks") }
        for p in peaks {
            XCTAssertGreaterThanOrEqual(p, 0.12)
            XCTAssertLessThanOrEqual(p, 1.0)
        }
        // Varied input must not produce a flat line.
        XCTAssertNotEqual(Set(peaks).count, 1)
    }

    func testDecodeFailureFailsOpenToNil() {
        struct Boom: Error {}
        let peaks = OggOpusWaveform.peaks(fromBytes: Data([0xFF])) { _ in
            throw Boom()
        }
        XCTAssertNil(peaks)
    }

    func testEmptyDecodeFailsOpenToNil() {
        let peaks = OggOpusWaveform.peaks(fromBytes: Data([0xFF])) { _ in [] }
        XCTAssertNil(peaks)
    }

    // MARK: - realWaveform shape invariants (best-effort on the sim)

    /// `realWaveform` runs AVAudioFile, which the simulator handles
    /// unreliably for Ogg. Whatever it returns, the contract is: nil OR a
    /// band-limited 40-bar array. (Load-bearing verification of non-nil output
    /// is the device smoke: the bubble bars must be non-uniform.)
    func testRealWaveformContractOnSampleFiles() {
        let writer = OggOpusFileWriter(channels: 1, preSkip: 240)
        for _ in 0..<50 { _ = try? writer.appendPacket(VoiceTestSupport.opusPacket(toc: 0x98)) }
        let bytes = Data(try! writer.finish())
        let peaks = OggOpusWaveform.realWaveform(from: bytes)
        guard let peaks else { return } // Sim decode may fail; that's the fail-open path.
        XCTAssertEqual(peaks.count, OggOpusWaveform.bars)
        for p in peaks {
            XCTAssertGreaterThanOrEqual(p, 0.12)
            XCTAssertLessThanOrEqual(p, 1.0)
        }
    }
}
