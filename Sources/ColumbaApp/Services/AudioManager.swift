//
//  AudioManager.swift
//  ColumbaApp
//
//  Audio capture and playback pipeline for LXST voice calls.
//  Manages AVAudioEngine, audio session lifecycle, and routes PCM frames
//  between the iOS audio hardware and the CallManager/Telephone codec layer.
//

import AVFoundation
import LXSTSwift
import os.log

/// Observable audio manager for LXST voice calls.
///
/// Handles the iOS-specific audio pipeline:
/// - Microphone capture via AVAudioEngine input tap
/// - Speaker/earpiece playback via AVAudioPlayerNode
/// - AVAudioSession configuration for voiceChat category
/// - Interruption handling (incoming phone calls, Siri, etc.)
/// - Output route switching (speaker vs earpiece)
/// - Mute and PTT gating of captured audio
///
/// Audio flows:
/// ```
/// Mic -> inputNode tap -> captureBuffer -> drainLoop -> onCapturedFrame callback
/// onPlaybackFrame -> playerNode.scheduleBuffer -> Speaker/Earpiece
/// ```
///
/// The actual codec encoding/decoding lives in the Telephone actor via
/// LXSTSwift's AudioPipeline. This class only handles raw PCM I/O.
@available(macOS 14.0, iOS 17.0, *)
@Observable
@MainActor
public final class AudioManager {

    // MARK: - Observable State

    /// Whether the audio engine is currently running.
    private(set) var isActive: Bool = false

    /// Current audio route description (e.g., "Speaker", "Receiver", "AirPods").
    private(set) var currentRoute: String = "Receiver"

    /// Peak input level (0.0-1.0) for UI metering, updated every frame.
    private(set) var inputLevel: Float = 0.0

    // MARK: - Configuration

    /// Sample rate for capture and playback (matches codec requirements).
    let sampleRate: Double

    /// Number of audio channels (1 for voice, 2 for high-quality profiles).
    let channels: Int

    /// Frame duration in milliseconds (determines buffer sizes).
    let frameTimeMs: Int

    /// Preferred IO buffer duration for low-latency audio.
    let ioBufferDuration: TimeInterval

    // MARK: - Callbacks

    /// Called with captured PCM Float32 samples ready for codec encoding.
    /// The frame size matches `samplesPerFrame` (sampleRate * frameTimeMs / 1000).
    ///
    /// TODO: Wire this to Telephone.sendAudioFrame() once the codec pipeline
    /// is connected. For now, CallManager can set this to forward frames.
    var onCapturedFrame: (([Float]) -> Void)?

    // MARK: - Private State

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var captureBuffer: AudioRingBuffer
    private var drainTask: Task<Void, Never>?
    private var deviceSampleRate: Double = 48000
    private let logger = Logger(subsystem: "com.columba.app", category: "AudioManager")

    /// Notification observers for audio session events.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    // MARK: - Computed

    /// Number of PCM samples per frame (per channel).
    var samplesPerFrame: Int {
        Int(sampleRate) * frameTimeMs / 1000
    }

    // MARK: - Initialization

    /// Create an AudioManager with explicit parameters.
    ///
    /// - Parameters:
    ///   - sampleRate: Target sample rate in Hz
    ///   - channels: Number of audio channels
    ///   - frameTimeMs: Frame duration in milliseconds
    ///   - ioBufferDuration: Preferred hardware IO buffer duration
    init(
        sampleRate: Double = 48000,
        channels: Int = 1,
        frameTimeMs: Int = 20,
        ioBufferDuration: TimeInterval = 0.005
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameTimeMs = frameTimeMs
        self.ioBufferDuration = ioBufferDuration

        // Ring buffer must hold at least one full device-rate frame.
        // For low-sample-rate codecs (e.g. Codec2 at 8kHz) with long frames (320ms),
        // inputSpf = samplesPerFrame * (devRate/codecRate) can be 15,000+ samples.
        // Assuming 48kHz device (worst case), size to 4× that for jitter headroom.
        let spf = Int(sampleRate) * frameTimeMs / 1000 * channels
        let estimatedDevRate = 48000.0
        let estimatedInputSpf = sampleRate < estimatedDevRate
            ? Int((Double(spf) * estimatedDevRate / sampleRate).rounded())
            : spf
        self.captureBuffer = AudioRingBuffer(capacity: max(estimatedInputSpf * 4, 4096))
    }

    /// Create an AudioManager from a TelephonyProfile.
    ///
    /// Extracts sample rate, channel count, and frame time from the profile's
    /// codec configuration.
    ///
    /// - Parameter profile: The active telephony profile for this call
    convenience init(profile: TelephonyProfile) {
        let rate: Double
        let ch: Int

        switch profile.codecType {
        case .opus:
            if let opus = profile.opusProfile {
                rate = Double(opus.sampleRate)
                ch = opus.channels
            } else {
                rate = 48000
                ch = 1
            }
        case .codec2:
            rate = Double(Codec2Mode.inputRate)
            ch = 1
        default:
            rate = 48000
            ch = 1
        }

        // Lower IO buffer for low-latency profiles
        let ioBuf: TimeInterval = profile.frameTimeMs <= 20 ? 0.005 : 0.01

        self.init(
            sampleRate: rate,
            channels: ch,
            frameTimeMs: profile.frameTimeMs,
            ioBufferDuration: ioBuf
        )
    }

    // Note: No deinit needed — stop() is always called before this object
    // is released, which removes notification observers and deactivates the
    // audio session. A deinit cannot access @MainActor properties safely.

    // MARK: - Audio Session

    /// Configure and activate the AVAudioSession for voice chat.
    ///
    /// Sets `.playAndRecord` category with `.voiceChat` mode, enables
    /// Bluetooth routing, and sets preferred buffer/sample rate.
    ///
    /// Note: `.defaultToSpeaker` is NOT used here because it conflicts with
    /// `.allowBluetoothA2DP` (Apple docs: combining them causes unexpected behavior).
    /// Speaker routing is handled via `overrideOutputAudioPort(.speaker)` after
    /// the session starts, which avoids this incompatibility.
    private func activateAudioSession(speakerEnabled: Bool) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()

        let options: AVAudioSession.CategoryOptions = [
            .allowBluetooth,
            .allowBluetoothA2DP
        ]

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: options
        )
        try session.setPreferredIOBufferDuration(ioBufferDuration)
        try session.setPreferredSampleRate(sampleRate)
        try session.setActive(true, options: [])

        logger.info("[AUDIO] Session activated: rate=\(self.sampleRate), ioBuf=\(self.ioBufferDuration)")
        #endif
    }

    /// Deactivate the AVAudioSession, allowing other apps to use audio.
    private func deactivateAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            logger.info("[AUDIO] Session deactivated")
        } catch {
            // Non-fatal: session deactivation can fail if another app is using audio
            logger.warning("[AUDIO] Session deactivation failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// Register for audio session interruption and route change notifications.
    private func registerSessionObservers() {
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRouteChange(notification)
            }
        }
        #endif
    }

    /// Remove audio session notification observers.
    private func removeSessionObservers() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }

    /// Handle audio session interruption (e.g., incoming phone call).
    private func handleInterruption(_ notification: Notification) {
        #if os(iOS)
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            logger.info("[AUDIO] Interruption began — pausing engine")
            engine?.pause()

        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                return
            }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                logger.info("[AUDIO] Interruption ended — resuming engine")
                do {
                    try engine?.start()
                } catch {
                    logger.error("[AUDIO] Failed to resume after interruption: \(error.localizedDescription)")
                }
            }

        @unknown default:
            break
        }
        #endif
    }

    /// Handle audio route changes (headphones plugged/unplugged, etc.).
    private func handleRouteChange(_ notification: Notification) {
        #if os(iOS)
        updateCurrentRoute()

        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            // Headphones unplugged — route to speaker or earpiece based on setting
            logger.info("[AUDIO] Output device removed, route updated to: \(self.currentRoute)")
        case .newDeviceAvailable:
            logger.info("[AUDIO] New output device available: \(self.currentRoute)")
        case .categoryChange:
            logger.info("[AUDIO] Audio category changed")
        default:
            break
        }
        #endif
    }

    /// Update the currentRoute property from the active audio session route.
    private func updateCurrentRoute() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        if let output = route.outputs.first {
            switch output.portType {
            case .builtInSpeaker:
                currentRoute = "Speaker"
            case .builtInReceiver:
                currentRoute = "Receiver"
            case .headphones:
                currentRoute = "Headphones"
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
                currentRoute = output.portName
            case .airPlay:
                currentRoute = "AirPlay"
            default:
                currentRoute = output.portName
            }
        }
        #else
        currentRoute = "Default"
        #endif
    }

    // MARK: - Start / Stop

    /// Start the full-duplex audio pipeline (capture + playback).
    ///
    /// Call this when a voice call is established. Configures the audio session,
    /// creates the AVAudioEngine, installs the input tap, and starts the
    /// playback player node.
    ///
    /// - Parameter speakerEnabled: If true, route output to speaker
    func start(speakerEnabled: Bool = false) {
        guard !isActive else {
            logger.warning("[AUDIO] Already active, ignoring start()")
            return
        }

        do {
            try activateAudioSession(speakerEnabled: speakerEnabled)
            registerSessionObservers()

            let eng = AVAudioEngine()
            self.engine = eng

            // --- Capture setup ---
            let inputNode = eng.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            deviceSampleRate = inputFormat.sampleRate

            let spf = samplesPerFrame
            let ch = channels
            let ringBuf = captureBuffer

            // The tap callback runs on a real-time thread — no locks, no allocation
            inputNode.installTap(
                onBus: 0,
                bufferSize: AVAudioFrameCount(spf),
                format: inputFormat
            ) { buffer, _ in
                guard let channelData = buffer.floatChannelData else { return }
                let frameCount = Int(buffer.frameLength)
                let srcChannels = Int(buffer.format.channelCount)

                if ch == 1 {
                    let ptr = channelData[0]
                    for i in 0..<frameCount {
                        ringBuf.write(ptr[i])
                    }
                } else {
                    for i in 0..<frameCount {
                        for c in 0..<min(srcChannels, ch) {
                            ringBuf.write(channelData[c][i])
                        }
                    }
                }
            }

            // --- Playback setup ---
            let player = AVAudioPlayerNode()
            eng.attach(player)

            guard let playbackFormat = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(channels)
            ) else {
                logger.error("[AUDIO] Failed to create playback format")
                return
            }

            eng.connect(player, to: eng.mainMixerNode, format: playbackFormat)

            // Start the engine (both capture and playback)
            try eng.start()
            player.play()

            self.playerNode = player
            isActive = true

            updateCurrentRoute()
            startDrainLoop()

            logger.error("[AUDIO] Pipeline started: capture=\(inputFormat.sampleRate)Hz, playback=\(self.sampleRate)Hz, frame=\(self.frameTimeMs)ms")

        } catch {
            logger.error("[AUDIO] Failed to start pipeline: \(error.localizedDescription)")
            stop()
        }
    }

    /// Stop the audio pipeline and release all resources.
    ///
    /// Call this when a voice call ends. Stops the engine, removes the input
    /// tap, deactivates the audio session, and cleans up observers.
    func stop() {
        drainTask?.cancel()
        drainTask = nil

        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            playerNode?.stop()
            eng.stop()
        }

        engine = nil
        playerNode = nil
        isActive = false
        inputLevel = 0.0
        playCount = 0

        removeSessionObservers()
        deactivateAudioSession()

        logger.info("[AUDIO] Pipeline stopped")
    }

    // MARK: - Speaker Routing

    /// Switch audio output between speaker and earpiece.
    ///
    /// - Parameter speakerOn: If true, route to built-in speaker; if false, route to receiver
    func setSpeakerEnabled(_ speakerOn: Bool) {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            if speakerOn {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
            updateCurrentRoute()
            logger.info("[AUDIO] Speaker: \(speakerOn ? "ON" : "OFF"), route: \(self.currentRoute)")
        } catch {
            logger.error("[AUDIO] Failed to set speaker: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Playback

    /// Schedule decoded PCM samples for playback through the speaker/earpiece.
    ///
    /// Call this when the Telephone actor delivers decoded audio frames.
    /// Handles buffer underruns gracefully by simply skipping frames (voice
    /// audio tolerates small gaps better than stuttering).
    ///
    /// TODO: Wire this to Telephone's decoded frame output once the codec
    /// pipeline is connected. CallManager should call this with decoded PCM data.
    ///
    /// - Parameter samples: Float32 PCM samples at the configured sample rate
    private var playCount: Int = 0

    func playDecodedAudio(_ samples: [Float]) {
        guard isActive, let player = playerNode, let eng = engine, eng.isRunning else {
            playCount += 1
            if playCount == 1 || playCount % 50 == 0 {
                logger.error("[AUDIO] playDecodedAudio DROPPED #\(self.playCount, privacy: .public): isActive=\(self.isActive, privacy: .public) engine=\(self.engine != nil, privacy: .public) running=\(self.engine?.isRunning ?? false, privacy: .public)")
            }
            return
        }
        playCount += 1
        if playCount == 1 || playCount % 100 == 0 {
            logger.error("[AUDIO] Scheduling playback buffer #\(self.playCount, privacy: .public): frames=\(samples.count / self.channels, privacy: .public) rate=\(self.sampleRate, privacy: .public)Hz")
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        ) else { return }

        let frameCount = samples.count / channels
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        if channels == 1 {
            let dest = buffer.floatChannelData![0]
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                dest.initialize(from: base, count: frameCount)
            }
        } else {
            // Deinterleave into separate channel buffers
            for ch in 0..<channels {
                let dest = buffer.floatChannelData![ch]
                for i in 0..<frameCount {
                    dest[i] = samples[i * channels + ch]
                }
            }
        }

        // scheduleBuffer is thread-safe; completion handler is nil to avoid overhead
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Capture Drain Loop

    /// Drain captured samples from the ring buffer and deliver to the callback.
    ///
    /// Runs on a background task, polling at half-frame intervals. When enough
    /// samples accumulate for a full frame, extracts them, resamples if the
    /// device rate differs from the target rate, and invokes the callback.
    private func startDrainLoop() {
        // outputSpf: how many target-rate samples the codec expects per frame
        let outputSpf = samplesPerFrame * channels
        // devRate/tgtRate are captured now (we're on MainActor); the hardware
        // rate is fixed once the engine starts and won't change during the call.
        let devRate = deviceSampleRate
        let tgtRate = sampleRate
        // inputSpf: how many device-rate samples from the ring buffer form exactly
        // one target-rate frame after resampling. Draining this many samples
        // and resampling produces exactly outputSpf samples for the codec.
        let inputSpf: Int
        if devRate > 0 && devRate != tgtRate {
            inputSpf = max(1, Int((Double(outputSpf) * devRate / tgtRate).rounded()))
        } else {
            inputSpf = outputSpf
        }
        let sleepNs = UInt64(frameTimeMs) * 500_000 // half frame time
        let ringBuf = captureBuffer
        let ch = channels

        logger.error("[AUDIO] DrainLoop: deviceRate=\(devRate)Hz targetRate=\(tgtRate)Hz inputSpf=\(inputSpf) outputSpf=\(outputSpf)")

        drainTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let available = ringBuf.count
                if available >= inputSpf {
                    // Extract one device-rate frame from ring buffer
                    var frame = [Float](repeating: 0, count: inputSpf)
                    for i in 0..<inputSpf {
                        frame[i] = ringBuf.read() ?? 0
                    }

                    // Resample to target rate — result is exactly outputSpf samples
                    let finalFrame: [Float]
                    if devRate != tgtRate {
                        if ch == 1 {
                            finalFrame = Resampler.resample(
                                frame,
                                fromRate: Int(devRate),
                                toRate: Int(tgtRate)
                            )
                        } else {
                            finalFrame = Resampler.resampleInterleaved(
                                frame,
                                channels: ch,
                                fromRate: Int(devRate),
                                toRate: Int(tgtRate)
                            )
                        }
                    } else {
                        finalFrame = frame
                    }

                    // Compute peak level for UI metering
                    let peak = finalFrame.reduce(Float(0)) { max($0, abs($1)) }

                    await MainActor.run {
                        self.inputLevel = peak
                        self.onCapturedFrame?(finalFrame)
                    }
                } else {
                    try? await Task.sleep(nanoseconds: sleepNs)
                }
            }
        }
    }
}

// MARK: - Lock-Free Ring Buffer (App-Local)

/// Single-producer single-consumer ring buffer for real-time audio transport.
///
/// The audio tap callback (real-time thread) writes samples; the drain loop
/// (async task) reads them. No locks or allocations in the write path.
///
/// This is a local copy tailored for AudioManager. LXSTSwift has its own
/// RingBuffer in AudioIO.swift for the library-level audio actor.
final class AudioRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        ptr.initialize(repeating: 0, count: capacity)
        self.storage = UnsafeMutableBufferPointer(start: ptr, count: capacity)
    }

    deinit {
        storage.baseAddress?.deinitialize(count: capacity)
        storage.baseAddress?.deallocate()
    }

    /// Number of samples available to read.
    var count: Int {
        let w = writeIndex
        let r = readIndex
        return w >= r ? (w - r) : (capacity - r + w)
    }

    /// Write a single sample. Overwrites oldest data if full (acceptable for voice).
    func write(_ value: Float) {
        storage[writeIndex] = value
        writeIndex = (writeIndex + 1) % capacity
    }

    /// Read a single sample. Returns nil if buffer is empty.
    func read() -> Float? {
        guard count > 0 else { return nil }
        let value = storage[readIndex]
        readIndex = (readIndex + 1) % capacity
        return value
    }
}
