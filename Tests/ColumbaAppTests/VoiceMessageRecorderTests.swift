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

    private static let c2Frames = 300
    private static let c2Samples = 320 * c2Frames   // codec2_2400: 320 spf

    // MARK: - Codec2 finalization

    func testStartThenStopFinalizesCodec2File() async throws {
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: Self.c2Samples))
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        defer { recorder.teardownEnginePreservingSelection() }

        let out = try recorder.start(format: .codec2_2400)
        XCTAssertTrue(recorder.isRecording)
        if case .recording = recorder.state {} else { XCTFail("expected .recording") }
        // The capture thread creates the file; wait for it (bounded).
        XCTAssertTrue(await VoiceTestSupport.awaitFile(at: out, exists: true),
                      "capture thread should create the .c2 file")

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
        let frames = rec.sizeBytes / 96
        XCTAssertEqual(rec.sizeBytes, frames * 96)
        // ~300 frames of 320 samples (8 kHz -> 8 kHz resample is ~identity).
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
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: Self.c2Samples))
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        defer { recorder.teardownEnginePreservingSelection() }
        let out = try recorder.start(format: .codec2_2400)
        _ = await VoiceTestSupport.awaitFile(at: out, exists: true)
        recorder.cancel()
        // cancel() is non-blocking: wait for the loop to delete the in-flight
        // file (done in onCaptureDone on the main actor).
        XCTAssertTrue(await VoiceTestSupport.awaitFile(at: out, exists: false, timeout: 5),
                      "cancelled in-flight file must be deleted")
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

    // MARK: - Double start rejected

    func testDoubleStartRejected() async throws {
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: Self.c2Samples))
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
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: Self.c2Samples))
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        let out = try recorder.start(format: .codec2_2400)
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
        let factory = FakeVoiceCaptureFactory(samples: VoiceTestSupport.pcm(count: Self.c2Samples))
        let recorder = VoiceMessageRecorder(captureFactory: factory)
        defer { recorder.teardownEnginePreservingSelection() }
        let out = try recorder.start(format: .codec2_2400)
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
