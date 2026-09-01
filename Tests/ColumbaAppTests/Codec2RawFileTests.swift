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
        let codec = try makeCodec(.codec2_2400)
        let geo = Codec2RawFile.geometry(for: .codec2_2400)
        let frame = VoiceTestSupport.pcm(count: geo.samplesPerFrame)
        let raw = try Codec2RawFile.encodeFrame(pcm: frame, codec: codec)
        // Raw frame size = bytesPerFrame (header byte removed).
        XCTAssertEqual(raw.count, geo.bytesPerFrame)
        // LXSTSwift encode prepends the header byte; stripping it must leave
        // exactly the frame bytes.
        let full = try codec.encode(frame)
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
        // Encode at 1200 (36-byte frames) but decode as 2400 (96-byte frames)
        // -> the byte count is not a whole number of 96-byte frames.
        let codec1200 = try makeCodec(.codec2_1200)
        let raw = try Codec2RawFile.encodeAll(pcm: VoiceTestSupport.pcm(count: 240 * 4), codec: codec1200)
        let codec2400 = try makeCodec(.codec2_2400)
        XCTAssertThrowsError(try Codec2RawFile.decode(raw, mode: .codec2_2400, codec: codec2400)) {
            XCTAssertEqual($0 as? Codec2FileError, .incompleteFrame)
        }
    }

    func testDecodeEnforcesFiveMinuteCeiling() {
        // 2400 geometry: 96-byte frames, 320 samples/frame. A payload sized as
        // a whole number of 2400 frames whose decoded samples exceed 5 minutes
        // (8000*300) must be rejected BEFORE any allocation (wide arithmetic).
        let geo = Codec2RawFile.geometry(for: .codec2_2400)
        // frames such that frames*320 > 2_400_000 (5 min at 8k).
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
        XCTAssertEqual(Int(littleEndian16(wav, 32)), 16)      // bits
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

    // MARK: - Geometry (libcodec2 table, bitrate × spf / 8000)

    func testGeometryTable() {
        let expectations: [Codec2Mode: (Int, Int)] = [
            .codec2_700C: (160, 14), .codec2_1200: (240, 36), .codec2_1300: (240, 39),
            .codec2_1400: (240, 42), .codec2_1600: (240, 48), .codec2_2400: (320, 96),
            .codec2_3200: (320, 128),
        ]
        for (mode, (spf, bpf)) in expectations {
            let g = Codec2RawFile.geometry(for: mode)
            XCTAssertEqual(g.samplesPerFrame, spf, "\(mode)")
            XCTAssertEqual(g.bytesPerFrame, bpf, "\(mode)")
            // Self-consistency: bytes = bitrate * spf / 8000.
            XCTAssertEqual(g.bytesPerFrame, Int(Double(mode.bitrate) * Double(g.samplesPerFrame) / 8000.0))
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
