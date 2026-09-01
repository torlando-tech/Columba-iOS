//
//  VoiceMessageRecorder.swift
//  ColumbaApp
//
//  Records a voice message to a finalized file (.c2 for Codec2, .ogg for
//  Ogg/Opus) in the chosen `VoiceMessageFormat`. Mirrors Android Columba's
//  `VoiceMessageRecorder` + `Codec2VoiceRecorderBackend` / LXST Ogg recorder:
//
//   - a single 5-minute deadline auto-stops a recording;
//   - a capture-worker failure atomically closes the engine, deletes the partial
//     file, and publishes a terminal `.failed` (never a silent success or a
//     stuck "recording");
//   - a finalized recording is retained across engine teardown (route change,
//     background, mic handoff) so it is not discarded while still selected by
//     the composer.
//
//  Threading model (matches AudioManager): the blocking read/encode loop runs on
a dedicated `Thread`; it snapshots the format/output/capture into locals and
only reads the locked `VoiceStopLatch` stop flag. All observable state is published by
//  hopping back to the `@MainActor` in `onCaptureDone`. `stop()`/`cancel()` are
//  NON-blocking: they flip the flag(s) and return; the loop self-terminates
//  (the capture `read` times out at 50 ms) and publishes the terminal state.
//  The UI observes `state` / `selectedRecording`. The capture source is
//  injectable so the state machine is testable without an audio device.
//

import Foundation
import Observation
import LXSTSwift
import AVFoundation

// MARK: - Capture abstraction

/// A source of raw int16 PCM (mono at a known rate) for one recording session.
/// `read` blocks up to a short timeout and returns the number of mono samples
/// delivered (0 on timeout / end), so a blocking read is interruptible by stop.
protocol VoicePcmCapture: AnyObject {
    var isSupported: Bool { get }
    var sampleRate: Int { get }
    func start() throws
    /// Read up to `capacity` mono samples into `buffer`. Returns samples read,
    /// or 0 on timeout. Returns -1 on a hard capture error.
    func read(into buffer: inout [Int16], capacity: Int) -> Int
    func stop()
    func close()
}

/// Factory for capture sessions (injected in tests; the real one wraps
/// AVAudioEngine).
protocol VoicePcmCaptureFactory: AnyObject {
    func makeCapture(channels: Int, sampleRateHint: Int) -> VoicePcmCapture
}

// MARK: - Output

/// A finalized recording ready to attach to a message.
public struct VoiceRecording: Equatable {
    public let url: URL
    public let format: VoiceMessageFormat
    public let durationMs: Int
    public let sizeBytes: Int
    public let audio: AudioAttachment
}

/// Recorder state (mirrors Android `VoiceMessageRecordingState`).
public enum VoiceRecorderState: Equatable {
    case idle
    case recording(elapsedMs: Int)
    case finalizing
    case completed(VoiceRecording)
    case failed(message: String)
}

public enum VoiceRecorderError: Error, Equatable {
    case alreadyRecording
    case unsupported
    case captureStartFailed
    case codecUnavailable
    case noAudio
}

// MARK: - Stop latch

/// Benign cross-thread stop latch (mirrors Android's `AtomicBoolean`): the
/// `@MainActor` recorder writes it, the capture thread reads it. Locked so the
/// cross-thread read is well-defined (a plain `var running` read on one thread
/// while written on another is undefined behavior).
final class VoiceStopLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var _running = false
    var running: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _running }
        set { lock.lock(); _running = newValue; lock.unlock() }
    }
}

// MARK: - Recorder

@available(iOS 17.0, *)
@Observable
@MainActor
public final class VoiceMessageRecorder {

    // Observable (UI-bound) state.
    public private(set) var state: VoiceRecorderState = .idle
    public private(set) var errorMessage: String? = nil
    public private(set) var selectedRecording: VoiceRecording? = nil
    public private(set) var selectedFormat: VoiceMessageFormat? = nil
    /// True when the last `start()` failure was because the device cannot
    /// record (as opposed to a transient capture error). Lets the composer
    /// panel show the dedicated "not supported" row, mirroring Android's
    /// `!isSupported` panel state.
    public private(set) var lastFailureWasUnsupported = false

    public static let maxDurationMillis = 5 * 60 * 1_000

    // Engine (not observed).
    @ObservationIgnored private let captureFactory: any VoicePcmCaptureFactory
    @ObservationIgnored private var capture: VoicePcmCapture?
    @ObservationIgnored private var format: VoiceMessageFormat?
    @ObservationIgnored private var outputFile: URL?
    @ObservationIgnored private var captureThread: Thread?
    /// Stop flag read on the capture thread via the locked `VoiceStopLatch`
    /// (mirrors Android's AtomicBoolean; `nonisolated`-safe by construction).
    @ObservationIgnored private let stopLatch = VoiceStopLatch()
    /// Cancel latch (distinct from a normal stop): a cancelled in-flight file is
    /// deleted rather than finalized.
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var elapsedMs = 0
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var workerFailure: Error? = nil

    public init(captureFactory: any VoicePcmCaptureFactory = AVEngineVoiceCaptureFactory()) {
        self.captureFactory = captureFactory
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: - Start

    @discardableResult
    public func start(format: VoiceMessageFormat) throws -> URL {
        if isRecording { throw VoiceRecorderError.alreadyRecording }
        lastFailureWasUnsupported = false
        let newCapture = captureFactory.makeCapture(
            channels: format.opusProfile?.channels ?? 1,
            sampleRateHint: format.opusProfile?.sampleRate ?? Codec2RawFile.sampleRate
        )
        guard newCapture.isSupported else {
            let msg = String(localized: "Voice messages are not supported on this device.")
            errorMessage = msg
            lastFailureWasUnsupported = true
            state = .failed(message: msg)
            throw VoiceRecorderError.unsupported
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-voice-notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = format.isCodec2 ? "c2" : "ogg"
        let out = dir.appendingPathComponent("voice_\(UUID().uuidString).\(ext)")
        self.outputFile = out
        self.format = format
        self.capture = newCapture
        self.cancelled = false
        self.workerFailure = nil

        do {
            try newCapture.start()
        } catch {
            newCapture.close()
            try? FileManager.default.removeItem(at: out)
            self.capture = nil
            self.outputFile = nil
            errorMessage = error.localizedDescription
            state = .failed(message: errorMessage!)
            throw VoiceRecorderError.captureStartFailed
        }

        // A new recording supersedes any prior (unsent) selection, as on Android.
        if let prior = selectedRecording {
            try? FileManager.default.removeItem(at: prior.url)
            selectedRecording = nil
            selectedFormat = nil
        }

        stopLatch.running = true
        elapsedMs = 0
        state = .recording(elapsedMs: 0)
        errorMessage = nil
        startElapsed()
        startDeadline()
        spawnCaptureThread()
        return out
    }

    // MARK: - Stop / cancel / remove (all non-blocking)

    /// Finalize the active recording. Flips the stop flag and returns; the
    /// capture loop self-terminates and publishes `.completed` (or `.failed`).
    public func stop() {
        guard stopLatch.running else { return }
        stopLatch.running = false
        cancelled = false
        state = .finalizing
    }

    /// Discard the active recording. The in-flight file (if any) is deleted by
    /// the capture loop's completion; an already-selected recording is cleared.
    public func cancel() {
        let wasRunning = stopLatch.running
        stopLatch.running = false
        cancelled = true
        if let sel = selectedRecording {
            try? FileManager.default.removeItem(at: sel.url)
            selectedRecording = nil
            selectedFormat = nil
        }
        state = .idle
        if !wasRunning {
            // No active loop to publish; ensure any stale engine is torn down.
            capture?.close()
            capture = nil
            stopElapsedAndDeadline()
        }
    }

    /// Remove a previously finalized (selected) recording from the composer.
    @discardableResult
    public func removeSelected() -> Bool {
        guard let sel = selectedRecording else { return false }
        try? FileManager.default.removeItem(at: sel.url)
        selectedRecording = nil
        selectedFormat = nil
        if case .completed = state { state = .idle }
        return true
    }

    /// Close the composer voice panel: tear down any active capture (the
    /// in-flight file is deleted) and clear the last error, returning to
    /// `.idle` with a clean ready row. Mirrors Android's panel `onCancel`.
    public func closePanel() {
        let wasRunning = stopLatch.running
        stopLatch.running = false
        cancelled = true
        if let sel = selectedRecording {
            try? FileManager.default.removeItem(at: sel.url)
            selectedRecording = nil
            selectedFormat = nil
        }
        errorMessage = nil
        lastFailureWasUnsupported = false
        state = .idle
        if !wasRunning {
            capture?.close()
            capture = nil
            stopElapsedAndDeadline()
        }
    }

    /// Tear down any active capture WITHOUT discarding a finalized recording
    /// still selected by the composer (route change / background / handoff).
    public func teardownEnginePreservingSelection() {
        if stopLatch.running {
            // Let the in-flight recording finalize and be retained.
            stopLatch.running = false
            cancelled = false
            state = .finalizing
            return
        }
        capture?.close()
        capture = nil
        stopElapsedAndDeadline()
        // selectedRecording / selectedFormat intentionally preserved.
    }

    // MARK: - Capture thread

    private func spawnCaptureThread() {
        // Snapshot the encode inputs so the capture thread only reads a plain
        // `running` latch (matching AudioManager's "snapshot then detach").
        guard let fmt = format, let out = outputFile, let cap = capture else {
            Task { @MainActor in self?.onCaptureDone(failed: nil) }
            return
        }
        // The loop runs nonisolated on the capture thread; the latch (not the
        // actor-isolated recorder) is the only shared stop signal.
        let latch = stopLatch
        let thread = Thread { [weak self] in
            self?.runCaptureLoop(capture: cap, format: fmt, out: out, latch: latch)
        }
        thread.qualityOfService = .userInitiated
        thread.name = "columba.voice.capture"
        captureThread = thread
        thread.start()
    }

    /// Runs on the dedicated capture thread. Nonisolated by design: it reads
    /// only its captured parameters and the stop latch, never actor-isolated
    /// state, and hops to the main actor to publish.
    nonisolated private func runCaptureLoop(
        capture: VoicePcmCapture, format: VoiceMessageFormat, out: URL,
        latch: VoiceStopLatch
    ) {
        var failed: Error? = nil
        do {
            if format.isCodec2, let c2 = format.codec2Mode {
                try runCodec2(capture: capture, mode: c2, out: out, latch: latch)
            } else if let profile = format.opusProfile {
                try runOpus(capture: capture, profile: profile, out: out, latch: latch)
            } else {
                failed = VoiceRecorderError.unsupported
            }
        } catch {
            failed = error
        }
        capture.stop()
        capture.close()
        Task { @MainActor [weak self, failed] in
            self?.onCaptureDone(failed: failed)
        }
    }

    /// Main-actor terminal transition, published after the capture thread exits.
    private func onCaptureDone(failed: Error?) {
        stopElapsedAndDeadline()
        let wasCancelled = cancelled
        let out = outputFile
        let fmt = format
        stopLatch.running = false
        capture = nil
        workerFailure = nil

        // A cancelled in-flight recording: delete the partial file, go idle.
        if wasCancelled {
            if let out { try? FileManager.default.removeItem(at: out) }
            outputFile = nil
            state = .idle
            return
        }

        guard let out, let fmt else {
            state = .idle
            return
        }

        if let failed {
            try? FileManager.default.removeItem(at: out)
            outputFile = nil
            errorMessage = failed.localizedDescription
            state = .failed(message: errorMessage!)
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        if !(FileManager.default.fileExists(atPath: out.path) && size > 0) {
            try? FileManager.default.removeItem(at: out)
            outputFile = nil
            errorMessage = String(localized: "Voice message recording produced no audio.")
            state = .failed(message: errorMessage!)
            return
        }

        let audio = Self.buildAudio(from: out, format: fmt, fallbackDurationMs: elapsedMs)
        let recording = VoiceRecording(url: out, format: fmt,
                                       durationMs: audio.durationMs ?? elapsedMs,
                                       sizeBytes: size, audio: audio)
        selectedRecording = recording
        selectedFormat = fmt
        state = .completed(recording)
        outputFile = nil
    }

    // MARK: - Encode loops (capture thread)

    nonisolated private func runCodec2(
        capture: VoicePcmCapture, mode: Codec2Mode, out: URL,
        latch: VoiceStopLatch
    ) throws {
        guard let codec = try? Codec2Codec(mode: mode) else { throw VoiceRecorderError.codecUnavailable }
        let geo = Codec2RawFile.geometry(for: mode)
        let deviceRate = max(1, capture.sampleRate)
        let cap = max(4096, geo.samplesPerFrame * 4)
        var buffer = [Int16](repeating: 0, count: cap)
        var accum = [Int16](); accum.reserveCapacity(geo.samplesPerFrame * 8)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let sink = try FileHandle(forWritingTo: out)
        defer { try? sink.close() }
        while latch.running {
            let n = capture.read(into: &buffer, capacity: cap)
            if !latch.running { break }
            if n < 0 { throw VoiceRecorderError.captureStartFailed }
            guard n > 0 else { continue } // 0 = timeout, keep polling the flag
            let down = Resampler.resampleInt16(Array(buffer[0..<n]), channels: 1,
                                               fromRate: deviceRate, toRate: Codec2RawFile.sampleRate)
            accum.append(contentsOf: down)
            while accum.count >= geo.samplesPerFrame {
                let frame = Array(accum.prefix(geo.samplesPerFrame))
                accum.removeFirst(geo.samplesPerFrame)
                let raw = try Codec2RawFile.encodeFrame(pcm: frame, codec: codec)
                try sink.write(contentsOf: raw)
            }
        }
    }

    nonisolated private func runOpus(
        capture: VoicePcmCapture, profile: OpusProfile, out: URL,
        latch: VoiceStopLatch
    ) throws {
        guard let codec = try? OpusCodec(profile: profile) else { throw VoiceRecorderError.codecUnavailable }
        let targetRate = profile.sampleRate
        let channels = profile.channels
        let framePerChannel = max(1, Int((Double(targetRate) * 0.06).rounded())) // 60 ms
        let preSkip = OggOpusFileWriter.preSkipForProfile(sampleRate: targetRate)
        let writer = OggOpusFileWriter(channels: channels, preSkip: preSkip)
        let deviceRate = max(1, capture.sampleRate)
        let cap = max(4096, framePerChannel * 4)
        var buffer = [Int16](repeating: 0, count: cap)
        var accum = [Int16](); accum.reserveCapacity(framePerChannel * channels * 8)
        while latch.running {
            let n = capture.read(into: &buffer, capacity: cap)
            if !latch.running { break }
            if n < 0 { throw VoiceRecorderError.captureStartFailed }
            guard n > 0 else { continue }
            let mono = Array(buffer[0..<n])
            let resampled: [Int16]
            if channels == 1 {
                resampled = Resampler.resampleInt16(mono, channels: 1,
                                                    fromRate: deviceRate, toRate: targetRate)
            } else {
                let m = Resampler.resampleInt16(mono, channels: 1,
                                                fromRate: deviceRate, toRate: targetRate)
                var stereo = [Int16](); stereo.reserveCapacity(m.count * 2)
                for s in m { stereo.append(s); stereo.append(s) }
                resampled = stereo
            }
            accum.append(contentsOf: resampled)
            let frameBytes = framePerChannel * channels
            while accum.count >= frameBytes {
                let frame = Array(accum.prefix(frameBytes))
                accum.removeFirst(frameBytes)
                let packet = try codec.encode(frame)
                try writer.appendPacket([UInt8](packet))
            }
        }
        let bytes = try writer.finish()
        try OggOpusFileWriter.publishToDisk(Data(bytes), to: out)
    }

    // MARK: - Timers

    private func startElapsed() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.stopLatch.running else { return }
                self.elapsedMs = min(self.elapsedMs + 1_000, Self.maxDurationMillis)
                if case .recording = self.state { self.state = .recording(elapsedMs: self.elapsedMs) }
            }
        }
    }

    private func startDeadline() {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maxDurationMillis) * 1_000_000)
            guard let self, self.stopLatch.running else { return }
            self.stop()
        }
    }

    private func stopElapsedAndDeadline() {
        elapsedTask?.cancel(); elapsedTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
    }

    // MARK: - Audio build

    private static func buildAudio(from url: URL, format: VoiceMessageFormat,
                                   fallbackDurationMs: Int) -> AudioAttachment {
        let data = (try? Data(contentsOf: url)) ?? Data()
        if !format.isCodec2, let meta = OggOpusMetadataReader.read([UInt8](data)) {
            return AudioAttachment(mode: format.audioMode, bytes: data, durationMs: meta.durationMs)
        }
        return AudioAttachment(mode: format.audioMode, bytes: data, durationMs: fallbackDurationMs)
    }
}

// MARK: - AVAudioEngine capture (real device)

/// AVAudioEngine-backed capture. A tap on the input node appends mono buffers to
/// an in-memory queue; `read` blocks (bounded) on a condition variable and
/// drains up to the requested capacity, returning 0 on timeout so a stop can
/// interrupt a blocking read.
@available(iOS 17.0, *)
final class AVEngineVoiceCapture: VoicePcmCapture {
    private let engine = AVAudioEngine()
    private let requestedRate: Int
    private(set) var deliveredRate = 44_100

    private let lock = NSLock()
    private let cond = NSCondition()
    private var queue: [Int16] = []
    private var isRunning = false
    private var hardError: Error?

    init(channels: Int, sampleRateHint: Int) {
        self.requestedRate = sampleRateHint
    }

    var isSupported: Bool {
        AVAudioSession.sharedInstance().recordPermission() == .granted
    }
    var sampleRate: Int { deliveredRate }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setPreferredSampleRate(Double(requestedRate))
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        deliveredRate = max(1, Int(hardware.sampleRate))
        // Deliver mono to the tap; the encode loop handles the profile's rate/channels.
        input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { return }
            var ints = [Int16](); ints.reserveCapacity(frames)
            for i in 0..<frames { ints.append(Int16(clamping: Int(data[0][i] * 32767))) }
            self.cond.lock()
            self.queue.append(contentsOf: ints)
            self.cond.signal()
            self.cond.unlock()
        }
        try engine.start()
        cond.lock(); isRunning = true; cond.unlock()
    }

    func read(into buffer: inout [Int16], capacity: Int) -> Int {
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(0.05)
        while true {
            if !isRunning { return 0 }
            if let e = hardError { hardError = nil; return -1 }
            if queue.count >= capacity {
                let head = Array(queue.prefix(capacity))
                queue.removeFirst(capacity)
                buffer.replaceSubrange(0..<capacity, with: head)
                return capacity
            }
            let now = Date()
            if now >= deadline { return 0 }
            cond.wait(until: min(deadline, now.addingTimeInterval(0.02)))
        }
    }

    func stop() {
        cond.lock()
        isRunning = false
        cond.signal()
        cond.unlock()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    func close() {
        stop()
        if let s = AVAudioSession.sharedInstance() { try? s.setActive(false) }
    }
}

@available(iOS 17.0, *)
final class AVEngineVoiceCaptureFactory: VoicePcmCaptureFactory {
    func makeCapture(channels: Int, sampleRateHint: Int) -> VoicePcmCapture {
        AVEngineVoiceCapture(channels: channels, sampleRateHint: sampleRateHint)
    }
}
