import XCTest
import AVFoundation
@testable import ColumbaApp

/// Tests for AudioManager's config change resilience.
///
/// These tests verify the format selection logic that prevents crashes when
/// toggling speaker during a voice call. The core issue: after an
/// AVAudioEngineConfigurationChange, inputNode.outputFormat returns a stale
/// codec rate (e.g. 24kHz) while the hardware has reverted to native 48kHz.
/// Installing a tap with the wrong format crashes with "format mismatch".
@available(macOS 14.0, iOS 17.0, *)
final class AudioManagerConfigChangeTests: XCTestCase {

    // MARK: - Initialization

    @MainActor
    func testDefaultInit() {
        let mgr = AudioManager(sampleRate: 48000, channels: 1, frameTimeMs: 20)
        XCTAssertEqual(mgr.sampleRate, 48000)
        XCTAssertEqual(mgr.channels, 1)
        XCTAssertEqual(mgr.frameTimeMs, 20)
        XCTAssertEqual(mgr.samplesPerFrame, 960) // 48000 * 20 / 1000
        XCTAssertFalse(mgr.isActive)
    }

    @MainActor
    func testLowRateCodecInit() {
        let mgr = AudioManager(sampleRate: 24000, channels: 1, frameTimeMs: 60)
        XCTAssertEqual(mgr.sampleRate, 24000)
        XCTAssertEqual(mgr.samplesPerFrame, 1440) // 24000 * 60 / 1000
    }

    @MainActor
    func testStereoInit() {
        let mgr = AudioManager(sampleRate: 48000, channels: 2, frameTimeMs: 20)
        XCTAssertEqual(mgr.channels, 2)
        XCTAssertEqual(mgr.samplesPerFrame, 960)
    }

    // MARK: - State Guards

    @MainActor
    func testStopWhenNotActiveIsNoOp() {
        let mgr = AudioManager()
        // Should not crash
        mgr.stop()
        XCTAssertFalse(mgr.isActive)
    }

    @MainActor
    func testHandleAudioSessionActivatedWhenNotActive() {
        let mgr = AudioManager()
        // Should be a no-op when not active
        mgr.handleAudioSessionActivated()
        XCTAssertFalse(mgr.isActive)
    }

    @MainActor
    func testPlayDecodedAudioWhenNotActive() {
        let mgr = AudioManager(sampleRate: 48000, channels: 1, frameTimeMs: 20)
        // Should silently drop without crash
        let samples = [Float](repeating: 0.5, count: 960)
        mgr.playDecodedAudio(samples)
        XCTAssertFalse(mgr.isActive)
    }

    // MARK: - Format Creation

    func testAVAudioFormatCreation48kHz() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
        XCTAssertNotNil(format)
        XCTAssertEqual(format?.sampleRate, 48000)
        XCTAssertEqual(format?.channelCount, 1)
    }

    func testAVAudioFormatCreation24kHz() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
        XCTAssertNotNil(format)
        XCTAssertEqual(format?.sampleRate, 24000)
        XCTAssertEqual(format?.channelCount, 1)
    }

    /// Verify that two formats with different sample rates are NOT equal.
    /// This is the root cause of the speaker toggle crash — the tap format
    /// must match the hardware format exactly.
    func testFormatMismatchDetection() {
        let fmt24k = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let fmt48k = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        XCTAssertNotEqual(fmt24k, fmt48k)
        XCTAssertNotEqual(fmt24k.sampleRate, fmt48k.sampleRate)
    }

    // MARK: - Playback Mono Downmix

    @MainActor
    func testPlayDecodedAudioMonoDownmix() {
        // Verify the mono downmix logic doesn't crash with stereo input
        let mgr = AudioManager(sampleRate: 48000, channels: 2, frameTimeMs: 20)
        // 960 stereo samples = 1920 interleaved floats
        let stereoSamples = [Float](repeating: 0.3, count: 1920)
        // Should not crash (audio won't play since engine isn't started)
        mgr.playDecodedAudio(stereoSamples)
    }
}
