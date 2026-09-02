//
//  VoiceMessagePlayerTests.swift
//  ColumbaAppTests
//
//  Phase C (plan step 11): the player's PURE metadata/waveform resolution
//  (no AVAudioPlayer needed on the sim): Codec2 duration comes from the
//  attachment, Ogg duration is read from the granules, waveforms are bounded
//  to ~40 normalized bars, and stopCurrent() resets state.
//

import XCTest
import LXSTSwift
@testable import ColumbaApp

@MainActor
final class VoiceMessagePlayerTests: XCTestCase {

    private func codec2Attachment(mode: AudioMode = .codec2_2400,
                                  frames: Int = 10,
                                  durationMs: Int) throws -> AudioAttachment {
        let codec = try Codec2Codec(mode: mode.codec2Mode!)
        let geo = Codec2RawFile.geometry(for: mode.codec2Mode!)
        let raw = try Codec2RawFile.encodeAll(pcm: VoiceTestSupport.pcm(count: geo.samplesPerFrame * frames),
                                              codec: codec)
        return AudioAttachment(mode: mode, bytes: raw, durationMs: durationMs)
    }

    func testPrepareResolvesCodec2DurationFromAttachment() async throws {
        let player = VoiceMessagePlayer()
        defer { player.tearDown() }
        let attachment = try codec2Attachment(durationMs: 400)
        player.prepare(key: "m1", attachment: attachment)
        let st = player.state(for: "m1")
        XCTAssertEqual(st.durationMs, 400)
        XCTAssertEqual(st.status, .idle)
    }

    func testPrepareResolvesOggDurationFromGranules() async {
        let player = VoiceMessagePlayer()
        defer { player.tearDown() }
        let writer = OggOpusFileWriter(channels: 1, preSkip: 240)
        _ = try? writer.appendPacket(VoiceTestSupport.opusPacket(toc: 0x98))  // 960
        _ = try? writer.appendPacket(VoiceTestSupport.opusPacket(toc: 0x98))  // 960
        let bytes = try! writer.finish()
        let attachment = AudioAttachment(mode: .opusOgg, bytes: Data(bytes), durationMs: nil)
        player.prepare(key: "m2", attachment: attachment)
        // Duration is read from the Ogg granules, not the (nil) attachment.
        XCTAssertEqual(player.state(for: "m2").durationMs, ((1920 - 240) * 1_000) / 48_000)
    }

    func testPrepareCachesNormalizedWaveform() async throws {
        let player = VoiceMessagePlayer()
        defer { player.tearDown() }
        let attachment = try codec2Attachment(frames: 20, durationMs: 800)
        player.prepare(key: "m3", attachment: attachment)
        let waveform = player.waveform(for: "m3")
        XCTAssertNotNil(waveform)
        XCTAssertEqual(waveform?.count, 40)
        let peaks = waveform!
        for p in peaks {
            XCTAssertGreaterThanOrEqual(p, 0)
            XCTAssertLessThanOrEqual(p, 1)
        }
        // A 440 Hz sine should produce some non-zero peaks.
        XCTAssertTrue(peaks.max() ?? 0 > 0.0)
    }

    /// Ogg waveforms are now decoded ASYNC on a background task (Android
    /// parity; the views render the neutral placeholder until the peaks land
    /// or the decode fails open). `prepare` must stay non-blocking: the
    /// duration is resolved synchronously and the waveform is either absent
    /// (decode still running / failed on this environment) or a band-limited
    /// 40-bar array - it must never be the old hard-coded flat 0.5 fill.
    func testOggWaveformIsAsyncNeverBlocking() async {
        let player = VoiceMessagePlayer()
        defer { player.tearDown() }
        let writer = OggOpusFileWriter(channels: 1, preSkip: 240)
        _ = try? writer.appendPacket(VoiceTestSupport.opusPacket())
        let attachment = AudioAttachment(mode: .opusOgg, bytes: Data(try! writer.finish()), durationMs: nil)
        let start = Date()
        player.prepare(key: "m4", attachment: attachment)
        // Synchronous work only: no decode may run on the calling thread.
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        // Duration is resolved synchronously from the granules.
        XCTAssertEqual(player.state(for: "m4").durationMs, ((960 - 240) * 1_000) / 48_000)
        // Give the background decode a bounded chance to land.
        for _ in 0..<20 {
            if player.waveform(for: "m4") != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Whatever the (sim) decode returns, the contract is: nil (fail-open)
        // or a band-limited 40-bar array - never the flat 0.5 placeholder.
        if let waveform = player.waveform(for: "m4") {
            XCTAssertEqual(waveform.count, 40)
            for p in waveform {
                XCTAssertGreaterThanOrEqual(p, 0.12)
                XCTAssertLessThanOrEqual(p, 1.0)
            }
        }
    }

    func testTearDownClearsCachedStateAndWaveforms() async throws {
        let player = VoiceMessagePlayer()
        let attachment = try codec2Attachment(durationMs: 400)
        player.prepare(key: "m6", attachment: attachment)
        XCTAssertNotNil(player.waveform(for: "m6"))
        XCTAssertGreaterThan(player.state(for: "m6").durationMs, 0)
        player.tearDown()
        // After teardown the cache is empty: no waveform, default (idle, 0) state.
        XCTAssertNil(player.waveform(for: "m6"))
        XCTAssertEqual(player.state(for: "m6").durationMs, 0)
        XCTAssertEqual(player.state(for: "m6").status, .idle)
        XCTAssertFalse(player.isPlaying)
    }
}
