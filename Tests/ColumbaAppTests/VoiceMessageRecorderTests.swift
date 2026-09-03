//
//  VoiceMessageRecorderTests.swift
//  ColumbaAppTests
//
//  Phase C (plan step 11): the recorder state machine with an injected
//  VoicePcmCaptureFactory (no audio device needed). Covers: backend selection
//  by format (.c2 vs .ogg), non-blocking stop -> .completed, worker-failure
//  cleanup (capture closed, partial file deleted, terminal state published),
//  empty-output .failed, cancel file deletion, unsupported-device terminal
//  state, double-start rejection, finalized-file retention across teardown,
//  and removeSelected().
//
//  NOTE: the fake capture types are FILE-SCOPE (not nested): the capture loop
//  runs on a plain Thread and calls them synchronously, so they must NOT be
//  implicitly @MainActor-isolated by living inside the @MainActor test class.
//

import XCTest
import LXSTSwift
@testable import ColumbaApp

// MARK: - File-scope capture fakes (nonisolated, safe for the capture thread)

/// Capture that starts fine but reports a hard error (-1) on the first read.
final class FailingReadVoiceCapture: VoicePcmCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var _closeCount = 0
    private var _stopCount = 0
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return _closeCount }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
    var isSupported: Bool { true }
    var sampleRate: Int { 8_000 }
    func start() throws {}
    func read(into buffer: inout [Int16], capacity: Int) -> Int { -1 }
    func stop() { lock.lock(); _stopCount += 1; lock.unlock() }
    func close() { lock.lock(); _closeCount += 1; lock.unlock() }
}

final class FailingReadVoiceCaptureFactory: VoicePcmCaptureFactory, @unchecked Sendable {
    let capture = FailingReadVoiceCapture()
    func makeCapture(channels: Int, sampleRateHint: Int) -> VoicePcmCapture { capture }
}

// MARK: - Recorder state machine

@MainActor
final class VoiceMessageRecorderTests: XCTestCase {

    /// Feed 300 frames' worth of samples. The samples-per-frame for a given
    /// Codec2 mode is derived from the LIVE codec (see
    /// `Codec2RawFile.geometry(of:)`), so we size the buffer off the live
    /// geometry rather than hardcoding an spf that may differ from what the
    /// bundled codec2 actually uses. codec2_2400 is 160 samples/frame in the
    /// C codec (NOT 320), so the old `320 * 300` buffer over-fed 2x and the
    /// (correct) recorder produced 600 frames instead of 300.
    private static func c2Samples(for mode: Codec2Mode, frames: Int) -> Int {
        let codec = try! Codec2Codec(mode: mode)
        let geo = Codec2RawFile.geometry(of: codec)
        return geo.samplesPerFrame * frames
    }

    // MARK: - Codec2 finalization

    func testStartThenStopFinalizesCodec2File() async throws {
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: Self.c2Samples(for: .codec2_2400, frames: 300)))
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        defer { recorder.teardownEnginePreservingSelection() }

        let out = try recorder.start(format: .codec2_2400)
        XCTAssertTrue(recorder.isRecording)
        if case .recording = recorder.state {} else { XCTFail("expected .recording") }
        // The capture thread creates the file; wait for it (bounded).
        let fileCreated = await VoiceTestSupport.awaitFile(at: out, exists: true)
        XCTAssertTrue(fileCreated, "capture thread should create the .c2 file")

        // Deterministic finalization gate: wait for the finite fake buffer to
        // be fully read AND for the encode loop to stop growing the file
        // (the final read-batch's frames are written after the read that
        // drained, so a file-exists or drain-only stop can drop them). Then
        // stop: every frame is already on disk.
        guard let cap = factory.madeCaptures.first else { XCTFail("no capture"); return }
        _ = await VoiceTestSupport.awaitDrained(cap)
        let settled = await VoiceTestSupport.awaitFileSettled(at: out)
        XCTAssertTrue(settled, "capture loop should settle before stop")

        recorder.stop()
        let state = await waitForRecorderState(recorder) { s in
            if case .completed = s { return true }; if case .failed = s { return true }; return false
        }
        guard case .completed(let rec) = state else {
            XCTFail("expected .completed, got \(state)"); return
        }
        XCTAssertEqual(rec.format, .codec2_2400)
        XCTAssertEqual(rec.url, out)
        XCTAssertEqual(rec.audio.mode, .codec2_2400)
        XCTAssertTrue(rec.audio.bytes.count > 0)
        // .c2 extension, size is a whole number of 2400 frames (96 bytes),
        // payload decodes cleanly (no header byte, complete frames only).
        XCTAssertEqual(out.pathExtension, "c2")
        // Frame size comes from the LIVE codec (bytes/frame), not a magic
        // number: the old test hardcoded 96 (the buggy table's bit-value).
        let bytesPerFrame = Codec2RawFile.geometry(for: .codec2_2400).bytesPerFrame
        let frames = rec.sizeBytes / bytesPerFrame
        XCTAssertEqual(rec.sizeBytes, frames * bytesPerFrame)
        // ~300 frames of 160 samples (codec2_2400 live spf; 8 kHz -> 8 kHz
        // resample is ~identity, so 300*160 = 48,000 samples -> 300 frames).
        XCTAssertTrue((295...305).contains(frames), "expected ~300 frames, got \(frames)")
        _ = try Codec2RawFile.decodePayload(rec.audio.bytes, mode: .codec2_2400)
        // Audio bytes mirror the file exactly (dual-write consistency).
        XCTAssertEqual(rec.audio.bytes, try Data(contentsOf: out))
        XCTAssertEqual(rec.audio.sizeBytes, rec.sizeBytes)
        // Codec2 duration is best-effort (wall-clock fallback), always set.
        XCTAssertNotNil(rec.audio.durationMs)
        // The capture was torn down by the loop.
        XCTAssertEqual(factory.madeCaptures.first?.closeCount, 1)
        XCTAssertTrue(recorder.selectedRecording != nil)
        XCTAssertEqual(recorder.selectedFormat, .codec2_2400)
    }

    // MARK: - Opus finalization

    func testStartThenStopFinalizesOggFile() async throws {
        // 8 kHz mono sine -> opusMedium (24 kHz mono): ~1.5x resample.
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: 192_000),
                                              rate: 8_000)
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        defer { recorder.teardownEnginePreservingSelection() }

        let out = try recorder.start(format: .opusMedium)
        // The Ogg file only appears at the END (atomic publish after all
        // packets are encoded), so it cannot be awaited pre-stop. Instead wait
        // for the finite fake buffer to be fully read: the loop then encodes
        // every packet and finishes on its own next iteration. (Production:
        // the mic never drains, so this gate is a no-op there.)
        guard let cap = factory.madeCaptures.first else { XCTFail("no capture"); return }
        _ = await VoiceTestSupport.awaitDrained(cap)
        recorder.stop()
        let state = await waitForRecorderState(recorder) { s in
            if case .completed = s { return true }; if case .failed = s { return true }; return false
        }
        guard case .completed(let rec) = state else {
            XCTFail("expected .completed, got \(state)"); return
        }
        XCTAssertEqual(rec.format, .opusMedium)
        XCTAssertEqual(rec.audio.mode, .opusOgg)
        XCTAssertEqual(out.pathExtension, "ogg")
        // The published file is a valid Ogg/Opus stream the metadata reader
        // accepts, and the attachment duration comes from the granules.
        let bytes = try Data(contentsOf: out)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x4F, 0x67, 0x67, 0x53])
        let meta = OggOpusMetadataReader.read([UInt8](bytes))
        XCTAssertNotNil(meta)
        XCTAssertEqual(rec.audio.durationMs, meta?.durationMs)
        XCTAssertGreaterThan(rec.audio.durationMs ?? 0, 0)
        XCTAssertEqual(rec.sizeBytes, bytes.count)
    }

    // MARK: - Empty output -> .failed, file deleted

    func testEmptyOutputFailsAndDeletesFile() async throws {
        let factory = FakeVoiceCaptureFactory(samples: [], rate: 8_000)
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        defer { recorder.teardownEnginePreservingSelection() }
        let out = try recorder.start(format: .codec2_2400)
        // Ensure the (empty) file exists, then stop so finalization runs.
        _ = await VoiceTestSupport.awaitFile(at: out, exists: true)
        recorder.stop()
        let state = await waitForRecorderState(recorder) { s in
            if case .failed = s { return true }; return false
        }
        guard case .failed(let message) = state else {
            XCTFail("expected .failed, got \(state)"); return
        }
        XCTAssertFalse(message.isEmpty)
        // onCaptureDone deletes the empty file before publishing .failed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                       "partial empty file must be deleted")
        XCTAssertNil(recorder.selectedRecording)
    }

    // MARK: - Worker failure -> .failed, capture closed, file deleted

    func testWorkerFailureClosesCaptureAndPublishesFailed() async throws {
        let factory = FailingReadVoiceCaptureFactory()
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        defer { recorder.teardownEnginePreservingSelection() }
        let out = try recorder.start(format: .codec2_2400)
        let state = await waitForRecorderState(recorder) { s in
            if case .failed = s { return true }; return false
        }
        guard case .failed = state else {
            XCTFail("expected .failed, got \(state)"); return
        }
        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertEqual(factory.capture.closeCount, 1)
        XCTAssertEqual(factory.capture.stopCount, 1)
        // The (empty) partial file is deleted on the failure path.
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testCaptureStartFailureClosesCaptureAndPublishesFailed() async {
        struct StartError: Error {}
        let factory = FakeVoiceCaptureFactory(startError: StartError())
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        XCTAssertThrowsError(try recorder.start(format: .codec2_2400)) {
            XCTAssertEqual($0 as? VoiceRecorderError, .captureStartFailed)
        }
        if case .failed = recorder.state {} else { XCTFail("expected .failed, got \(recorder.state)") }
        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertEqual(factory.madeCaptures.first?.closeCount, 1)
    }

    // MARK: - Cancel deletes in-flight file

    func testCancelDeletesInFlightFileAndGoesIdle() async throws {
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: Self.c2Samples(for: .codec2_2400, frames: 300)))
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        defer { recorder.teardownEnginePreservingSelection() }
        let out = try recorder.start(format: .codec2_2400)
        _ = await VoiceTestSupport.awaitFile(at: out, exists: true)
        recorder.cancel()
        // cancel() is non-blocking: wait for the loop to delete the in-flight
        // file (done in onCaptureDone on the main actor).
        let fileDeleted = await VoiceTestSupport.awaitFile(at: out, exists: false, timeout: 5)
        XCTAssertTrue(fileDeleted, "cancelled in-flight file must be deleted")
        XCTAssertEqual(factory.madeCaptures.first?.closeCount, 1)
        XCTAssertEqual(factory.madeCaptures.first?.stopCount, 1)
        XCTAssertNil(recorder.selectedRecording)
        if case .idle = recorder.state {} else { XCTFail("expected .idle, got \(recorder.state)") }
    }

    // MARK: - Unsupported device

    func testUnsupportedDevicePublishesTerminalFailed() async {
        let factory = FakeVoiceCaptureFactory(supported: false)
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        XCTAssertThrowsError(try recorder.start(format: .codec2_1200)) {
            XCTAssertEqual($0 as? VoiceRecorderError, .unsupported)
        }
        if case .failed = recorder.state {} else { XCTFail("expected .failed, got \(recorder.state)") }
        XCTAssertTrue(recorder.lastFailureWasUnsupported)
        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertNil(recorder.selectedRecording)
    }

    // MARK: - Capture start() throwing .unsupported (degenerate input format)

    func testCaptureStartThrowingUnsupportedPublishesTerminalUnsupported() async {
        // Mirrors the production abort guard: the capture reports supported
        // (permission granted) but start() throws .unsupported when the
        // input format is degenerate (no usable input device). The recorder
        // must surface the dedicated unsupported state, not a generic
        // captureStartFailed, so the composer shows the "not supported on
        // this device" row (Android !isSupported parity).
        let factory = FakeVoiceCaptureFactory(startError: VoiceRecorderError.unsupported, supported: true)
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        XCTAssertThrowsError(try recorder.start(format: .opusMedium)) {
            XCTAssertEqual($0 as? VoiceRecorderError, .unsupported)
        }
        if case .failed = recorder.state {} else { XCTFail("expected .failed, got \(recorder.state)") }
        XCTAssertTrue(recorder.lastFailureWasUnsupported)
        XCTAssertEqual(recorder.errorMessage, "Voice messages are not supported on this device.")
        // The capture must be closed and no partial file left behind.
        XCTAssertEqual(factory.madeCaptures.first?.closeCount, 1)
        XCTAssertNil(recorder.selectedRecording)
    }

    // MARK: - Double start rejected

    func testDoubleStartRejected() async throws {
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: Self.c2Samples(for: .codec2_2400, frames: 300)))
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        defer { recorder.teardownEnginePreservingSelection() }
        _ = try recorder.start(format: .codec2_2400)
        XCTAssertThrowsError(try recorder.start(format: .opusMedium)) {
            XCTAssertEqual($0 as? VoiceRecorderError, .alreadyRecording)
        }
        recorder.stop()
        _ = await waitForRecorderState(recorder) { s in
            if case .completed = s { return true }; if case .failed = s { return true }; return false
        }
    }

    // MARK: - Finalized file retained across teardown

    func testTeardownRetainsFinalizedRecording() async throws {
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: Self.c2Samples(for: .codec2_2400, frames: 300)))
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        let out = try recorder.start(format: .codec2_2400)
        // Let the finite fake buffer drain and the loop settle so the stop
        // finalizes a complete (non-empty) recording - see the codec2 test.
        if let cap = factory.madeCaptures.first {
            _ = await VoiceTestSupport.awaitDrained(cap)
            _ = await VoiceTestSupport.awaitFileSettled(at: out)
        }
        recorder.stop()
        _ = await waitForRecorderState(recorder) { s in
            if case .completed = s { return true }; if case .failed = s { return true }; return false
        }
        XCTAssertNotNil(recorder.selectedRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        // Simulate route change / background: engine torn down, selection kept.
        recorder.teardownEnginePreservingSelection()
        XCTAssertEqual(recorder.selectedRecording?.url, out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        if case .completed = recorder.state {} else { XCTFail("expected .completed, got \(recorder.state)") }
    }

    // MARK: - removeSelected

    func testRemoveSelectedDeletesFileAndClearsState() async throws {
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: Self.c2Samples(for: .codec2_2400, frames: 300)))
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        defer { recorder.teardownEnginePreservingSelection() }
        let out = try recorder.start(format: .codec2_2400)
        if let cap = factory.madeCaptures.first {
            _ = await VoiceTestSupport.awaitDrained(cap)
            _ = await VoiceTestSupport.awaitFileSettled(at: out)
        }
        recorder.stop()
        _ = await waitForRecorderState(recorder) { s in
            if case .completed = s { return true }; if case .failed = s { return true }; return false
        }
        XCTAssertTrue(recorder.removeSelected())
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertNil(recorder.selectedRecording)
        XCTAssertNil(recorder.selectedFormat)
        if case .idle = recorder.state {} else { XCTFail("expected .idle, got \(recorder.state)") }
        XCTAssertFalse(recorder.removeSelected(), "second remove must be a no-op")
    }
}
