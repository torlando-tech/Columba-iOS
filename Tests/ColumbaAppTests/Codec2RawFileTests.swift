//
//  Codec2RawFileTests.swift
//  ColumbaAppTests
//
//  Phase B (plan step 8): the Codec2 raw-frame file codec. Pins the interop
//  contract: NO telephone header byte on disk/wire, raw complete-frame
//  concatenation, the header byte prefixed only at decode time, the
//  bitrate×samplesPerFrame/8000 geometry, the 5-minute decode ceiling, and a
//  valid WAV bridge for AVAudioPlayer.
//

import XCTest
import Foundation
import LXSTSwift
@testable import ColumbaApp

final class Codec2RawFileTests: XCTestCase {

    private func makeCodec(_ mode: Codec2Mode = .codec2_2400) throws -> Codec2Codec {
        try Codec2Codec(mode: mode)
    }

    // MARK: - Encode (header stripped)

    func testEncodeFrameStripsHeaderByte() throws {
        // Codec2 is a STATEFUL codec: consecutive encode() calls on the same
        // instance keep internal state and produce different bytes. So the
        // "encodeFrame strips the header" invariant is checked by encoding the
        // SAME pcm with a FRESH codec on each side - then the only difference
        // between `codec.encode(frame)` and `encodeFrame` is the header byte.
        let geo = Codec2RawFile.geometry(for: .codec2_2400)
        let frame = VoiceTestSupport.pcm(count: geo.samplesPerFrame)
        let a = try makeCodec(.codec2_2400)
        let b = try makeCodec(.codec2_2400)
        let raw = try Codec2RawFile.encodeFrame(pcm: frame, codec: a)
        // Raw frame size = bytesPerFrame (header byte removed).
        XCTAssertEqual(raw.count, geo.bytesPerFrame)
        // LXSTSwift encode prepends the header byte; stripping it must leave
        // exactly the frame bytes (encoded fresh, so the payload is identical).
        let full = try b.encode(frame)
        XCTAssertEqual(full.count, geo.bytesPerFrame + 1)
        XCTAssertEqual(full[0], 0x05, "LXST header byte for codec2_2400")
        XCTAssertEqual(Array(full[1...]), Array(raw))
    }

    func testEncodeFrameRejectsEmpty() {
        let codec = try! makeCodec()
        XCTAssertThrowsError(try Codec2RawFile.encodeFrame(pcm: [], codec: codec)) {
            XCTAssertEqual($0 as? Codec2FileError, .emptyPcm)
        }
    }

    // MARK: - Decode (header prefixed, bounds enforced)

    func testDecodeRoundTrip() throws {
        let codec = try makeCodec(.codec2_2400)
        let geo = Codec2RawFile.geometry(for: .codec2_2400)
        let pcm = VoiceTestSupport.pcm(count: geo.samplesPerFrame * 5)
        let raw = try Codec2RawFile.encodeAll(pcm: pcm, codec: codec)
        XCTAssertEqual(raw.count, geo.bytesPerFrame * 5)
        let decoded = try Codec2RawFile.decode(raw, mode: .codec2_2400, codec: codec)
        XCTAssertEqual(decoded.sampleRateHz, 8_000)
        XCTAssertEqual(decoded.samples.count, geo.samplesPerFrame * 5)
        XCTAssertEqual(decoded.durationMs, (geo.samplesPerFrame * 5) * 1_000 / 8_000)
    }

    func testDecodePayloadConvenience() throws {
        let codec = try makeCodec(.codec2_3200)
        let geo = Codec2RawFile.geometry(for: .codec2_3200)
        let raw = try Codec2RawFile.encodeAll(pcm: VoiceTestSupport.pcm(count: geo.samplesPerFrame * 3),
                                              codec: codec)
        let decoded = try Codec2RawFile.decodePayload(raw, mode: .codec2_3200)
        XCTAssertEqual(decoded.samples.count, geo.samplesPerFrame * 3)
    }

    func testDecodeRejectsIncompleteTail() throws {
        let codec = try makeCodec(.codec2_2400)
        let geo = Codec2RawFile.geometry(for: .codec2_2400)
        let raw = try Codec2RawFile.encodeAll(pcm: VoiceTestSupport.pcm(count: geo.samplesPerFrame * 2),
                                              codec: codec)
        var bad = [UInt8](raw)
        bad.append(0xAB) // one extra byte -> not a whole number of frames
        XCTAssertThrowsError(try Codec2RawFile.decode(Data(bad), mode: .codec2_2400, codec: codec)) {
            XCTAssertEqual($0 as? Codec2FileError, .incompleteFrame)
        }
    }

    func testDecodeRejectsEmptyAndWrongMode() throws {
        let codec = try makeCodec()
        XCTAssertThrowsError(try Codec2RawFile.decode(Data(), mode: .codec2_2400, codec: codec)) {
            XCTAssertEqual($0 as? Codec2FileError, .noFrames)
        }
        // Non-Codec2 mode has no header byte to prefix.
        let one = try Codec2RawFile.encodeAll(pcm: VoiceTestSupport.pcm(count: 320), codec: codec)
        XCTAssertThrowsError(try Codec2RawFile.decode(one, mode: .opusOgg, codec: codec)) {
            XCTAssertEqual($0 as? Codec2FileError, .noFrames)
        }
    }

    func testDecodeRejectsWrongCodecGeometry() throws {
        // A payload whose byte count is NOT a whole number of frames must be
        // rejected as incomplete, regardless of the exact frame size. Sized as
        // (frames × bytesPerFrame) + 1 from the LIVE geometry so the test is
        // robust to the real codec's bytesPerFrame (the old version assumed
        // 1200/2400 frame sizes whose ratio happened to work with the buggy
        // 8x-inflated table).
        let codec2400 = try makeCodec(.codec2_2400)
        let geo = Codec2RawFile.geometry(of: codec2400)
        let raw = try Codec2RawFile.encodeAll(
            pcm: VoiceTestSupport.pcm(count: geo.samplesPerFrame * 4), codec: codec2400)
        var bad = [UInt8](raw); bad.append(0xAB) // one extra byte
        XCTAssertThrowsError(try Codec2RawFile.decode(Data(bad), mode: .codec2_2400, codec: codec2400)) {
            XCTAssertEqual($0 as? Codec2FileError, .incompleteFrame)
        }
    }

    func testDecodeEnforcesFiveMinuteCeiling() {
        // A payload sized as a whole number of 2400 frames whose decoded
        // samples exceed 5 minutes (8000*300) must be rejected BEFORE any
        // allocation (wide arithmetic). Uses the live geometry's frame size.
        let geo = Codec2RawFile.geometry(for: .codec2_2400)
        // frames such that frames*spf > 2_400_000 (5 min at 8k).
        let frames = 8_000 * 300 / geo.samplesPerFrame + 1
        let payload = Data(repeating: 0x00, count: frames * geo.bytesPerFrame)
        XCTAssertThrowsError(try Codec2RawFile.decode(payload, mode: .codec2_2400, codec: try! makeCodec(.codec2_2400))) {
            XCTAssertEqual($0 as? Codec2FileError, .exceedsDecodeCeiling)
        }
    }

    // MARK: - WAV bridge

    func testWriteWaveProducesValidRIFF() throws {
        let codec = try makeCodec(.codec2_1600)
        let geo = Codec2RawFile.geometry(for: .codec2_1600)
        let raw = try Codec2RawFile.encodeAll(pcm: VoiceTestSupport.pcm(count: geo.samplesPerFrame * 2),
                                              codec: codec)
        let decoded = try Codec2RawFile.decode(raw, mode: .codec2_1600, codec: codec)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-voice-tests-\(UUID().uuidString)", isDirectory: true)
        // writeWave writes the WAV to `url` without creating the parent dir
        // (the production player creates its own). Create it here.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Codec2RawFile.writeWave(decoded, to: dir.appendingPathComponent("v.wav"))

        let wav = try Data(contentsOf: url)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(Int(littleEndian32(wav, 4)), 36 + decoded.samples.count * 2)
        XCTAssertEqual(wav[8..<12], Data("WAVE".utf8))
        XCTAssertEqual(wav[12..<16], Data("fmt ".utf8))
        XCTAssertEqual(Int(littleEndian32(wav, 16)), 16)      // fmt size
        XCTAssertEqual(Int(littleEndian16(wav, 20)), 1)       // PCM
        XCTAssertEqual(Int(littleEndian16(wav, 22)), 1)       // mono
        XCTAssertEqual(Int(littleEndian32(wav, 24)), 8_000)   // rate
        XCTAssertEqual(Int(littleEndian32(wav, 28)), 16_000)  // byte rate
        XCTAssertEqual(Int(littleEndian16(wav, 32)), 2)       // block align
        XCTAssertEqual(Int(littleEndian16(wav, 34)), 16)      // bits per sample
        XCTAssertEqual(wav[36..<40], Data("data".utf8))
        XCTAssertEqual(Int(littleEndian32(wav, 40)), decoded.samples.count * 2)
    }

    func testLargeRoundTripIsStable() throws {
        let codec = try makeCodec(.codec2_1200)
        let geo = Codec2RawFile.geometry(for: .codec2_1200)
        let frames = 50
        let raw = try Codec2RawFile.encodeAll(pcm: VoiceTestSupport.pcm(count: geo.samplesPerFrame * frames),
                                              codec: codec)
        XCTAssertEqual(raw.count, geo.bytesPerFrame * frames)
        let decoded = try Codec2RawFile.decode(raw, mode: .codec2_1200, codec: codec)
        XCTAssertEqual(decoded.samples.count, geo.samplesPerFrame * frames)
    }

    // MARK: - Geometry (derived from the live codec)

    /// The derived geometry must be self-consistent with the codec itself, for
    /// every mode: N frames of `samplesPerFrame` samples encode to exactly
    /// N × bytesPerFrame raw bytes, and `samplesPerFrame - 1` samples is not
    /// enough for one frame (encode throws). The live codec is the oracle -
    /// the old static table hardcoded (spf, bpf) pairs whose bpf was 8x too
    /// large (computed in bits, not bytes), which broke every encode/decode
    /// size assertion.
    func testGeometryMatchesLiveCodec() throws {
        for mode in Codec2Mode.allCases {
            let codec = try makeCodec(mode)
            let g = Codec2RawFile.geometry(of: codec)
            XCTAssertGreaterThan(g.samplesPerFrame, 0, "\(mode): samplesPerFrame")
            XCTAssertGreaterThan(g.bytesPerFrame, 0, "\(mode): bytesPerFrame")
            // 3 full frames -> exactly 3 × bytesPerFrame raw bytes.
            let raw = try Codec2RawFile.encodeAll(
                pcm: VoiceTestSupport.pcm(count: g.samplesPerFrame * 3), codec: codec)
            XCTAssertEqual(raw.count, g.bytesPerFrame * 3, "\(mode): 3-frame raw size")
            // samplesPerFrame - 1 samples cannot make one frame.
            XCTAssertThrowsError(
                try codec.encode(VoiceTestSupport.pcm(count: g.samplesPerFrame - 1)),
                "\(mode): one frame below spf must throw")
        }
    }

    private func littleEndian16(_ d: Data, _ off: Int) -> UInt16 {
        UInt16(d[d.startIndex + off]) | (UInt16(d[d.startIndex + off + 1]) << 8)
    }
    private func littleEndian32(_ d: Data, _ off: Int) -> UInt32 {
        UInt32(d[d.startIndex + off]) | (UInt32(d[d.startIndex + off + 1]) << 8)
        | (UInt32(d[d.startIndex + off + 2]) << 16) | (UInt32(d[d.startIndex + off + 3]) << 24)
    }
}
