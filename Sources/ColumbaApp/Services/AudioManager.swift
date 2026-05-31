//
//  AudioManager.swift
//  ColumbaApp
//
//  Audio capture and playback pipeline for LXST voice calls.
//  Manages AVAudioEngine, audio session lifecycle, and routes PCM frames
//  between the iOS audio hardware and the CallManager/Telephone codec layer.
//

import AVFoundation
import RNSAPI
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
    /// CallManager sets this to forward frames to `Telephone.sendAudioFrame`.
    var onCapturedFrame: (([Float]) -> Void)?

    // MARK: - Private State

    private(set) var engine: AVAudioEngine?
    private(set) var playerNode: AVAudioPlayerNode?
    private var captureBuffer: AudioRingBuffer
    private var drainTask: Task<Void, Never>?
    private var deviceSampleRate: Double = 48000
    /// Saved hardware input format from start(). Reused in config change / session
    /// activation handlers to avoid querying inputNode after stop() (returns stale
    /// codec format instead of real HW format, causing tap format mismatch crash).
    private var hwInputFormat: AVAudioFormat?
    private var hwInputChannels: Int = 1
    /// Actual hardware output channel count (1 in voiceChat mode, ≥1 otherwise).
    /// Set in start() from the engine's output node. Used to downmix decoded
    /// stereo frames to mono when the hardware can't play stereo.
    private var hwOutputChannels: Int = 1
    private let logger = Logger(subsystem: "network.columba.Columba", category: "AudioManager")

    /// Notification observers for audio session events.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var engineConfigObserver: NSObjectProtocol?

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

        if speakerEnabled {
            try session.overrideOutputAudioPort(.speaker)
        }

        logger.info("[AUDIO] Session activated: rate=\(self.sampleRate), ioBuf=\(self.ioBufferDuration), speaker=\(speakerEnabled)")
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
        if let observer = engineConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigObserver = nil
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
            updateCurrentRoute()
            logger.error("[AUDIO] Audio category changed, route=\(self.currentRoute, privacy: .public), engineRunning=\(self.engine?.isRunning ?? false, privacy: .public), playerPlaying=\(self.playerNode?.isPlaying ?? false, privacy: .public)")
            // Category change can break player→mixer connections silently.
            // Do a full reconnection as defense (same as handleEngineConfigurationChange).
            if let eng = engine, let player = playerNode, isActive {
                eng.disconnectNodeOutput(player)
                if let playbackFormat = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate,
                    channels: 1
                ) {
                    eng.connect(player, to: eng.mainMixerNode, format: playbackFormat)
                }
                if !eng.isRunning {
                    try? eng.start()
                }
                player.play()
                logger.error("[AUDIO] Reconnected player after category change")
            }
        default:
            break
        }
        #endif
    }

    /// Restart the audio capture pipeline after CallKit activates the audio session.
    ///
    /// For incoming calls, `AudioManager.start()` runs BEFORE CallKit's
    /// `didActivateAudioSession` fires. The AVAudioEngine input tap is installed
    /// but the audio session isn't yet activated by CallKit, so the mic produces
    /// no data. When CallKit activates the session, we must stop the engine,
    /// remove the old tap, reinstall it (picking up the new session config),
    /// and restart — this makes the mic start producing audio.
    func handleAudioSessionActivated() {
        guard isActive, let eng = engine else {
            DiagLog.log("[AUDIO] handleAudioSessionActivated — not active, skipping")
            return
        }
        DiagLog.log("[AUDIO] handleAudioSessionActivated — restarting capture pipeline")

        // Stop engine so we can remove/reinstall the tap
        eng.stop()
        eng.inputNode.removeTap(onBus: 0)

        // Install tap with format: nil — lets AVAudioEngine use the input node's
        // native format. After stop(), querying inputNode.outputFormat returns stale
        // data, so we can't trust an explicit format here.
        let spf = samplesPerFrame
        let ch = channels
        let ringBuf = captureBuffer

        eng.inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(spf),
            format: nil
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

        // Reconnect player node (connections broken by stop)
        if let player = playerNode {
            eng.disconnectNodeOutput(player)
            if let playbackFormat = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            ) {
                eng.connect(player, to: eng.mainMixerNode, format: playbackFormat)
            }
        }

        // Restart engine + player + drain loop
        do {
            try eng.start()
            playerNode?.play()

            // Query real format AFTER start — now the engine reports actual HW values
            let freshFormat = eng.inputNode.outputFormat(forBus: 0)
            if freshFormat.sampleRate > 0 && freshFormat.channelCount > 0 {
                hwInputFormat = freshFormat
                hwInputChannels = Int(freshFormat.channelCount)
                deviceSampleRate = freshFormat.sampleRate
            }

            // Restart drain loop with fresh hw channel count
            drainTask?.cancel()
            startDrainLoop(hwChannels: hwInputChannels)

            DiagLog.log("[AUDIO] Capture restarted after session activation: \(freshFormat.sampleRate)Hz \(self.hwInputChannels)ch")
            logger.error("[AUDIO] Capture restarted after session activation: \(freshFormat.sampleRate, privacy: .public)Hz \(self.hwInputChannels, privacy: .public)ch")
        } catch {
            DiagLog.log("[AUDIO] Failed to restart after session activation: \(error.localizedDescription)")
            logger.error("[AUDIO] Failed to restart after session activation: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Handle AVAudioEngine configuration changes.
    ///
    /// Fired when the audio hardware changes while the engine is running — most
    /// commonly caused by CallKit's `provider(_:didActivateAudioSession:)` calling
    /// `setCategory` with different options after AudioManager has already started.
    ///
    /// Per Apple docs: "If the audio hardware changes, the engine will stop and all
    /// connections between nodes will be broken." We must RECONNECT the player before
    /// restarting — without this, `scheduleBuffer()` queues buffers to a disconnected
    /// node and produces silence even though `isRunning` and `isPlaying` both appear true.
    private func handleEngineConfigurationChange() {
        guard let eng = engine, isActive else { return }
        logger.error("[AUDIO] Config change: engineRunning=\(eng.isRunning, privacy: .public)")

        do {
            // Do NOT call eng.stop() — iOS already stopped the engine on config change.

            // Remove old tap — it is invalidated by the config change.
            eng.inputNode.removeTap(onBus: 0)

            // After a config change (e.g. speaker toggle), inputNode.outputFormat
            // returns the STALE codec rate (24kHz) even though the real hardware has
            // reverted to native 48kHz. AVAudioSession.sampleRate returns the ACTUAL
            // hardware rate, which we must use for the tap format.
            #if os(iOS)
            let actualHwRate = AVAudioSession.sharedInstance().sampleRate
            #else
            let actualHwRate = deviceSampleRate
            #endif

            guard let tapFormat = AVAudioFormat(
                standardFormatWithSampleRate: actualHwRate,
                channels: 1
            ) else {
                logger.error("[AUDIO] Failed to create tap format at \(actualHwRate, privacy: .public)Hz")
                return
            }

            logger.error("[AUDIO] Config change: sessionRate=\(actualHwRate, privacy: .public)Hz, inputNodeRate=\(eng.inputNode.outputFormat(forBus: 0).sampleRate, privacy: .public)Hz")

            let spf = samplesPerFrame
            let ch = channels
            let ringBuf = captureBuffer
            eng.inputNode.installTap(
                onBus: 0,
                bufferSize: AVAudioFrameCount(spf),
                format: tapFormat
            ) { buffer, _ in
                guard let channelData = buffer.floatChannelData else { return }
                let frameCount = Int(buffer.frameLength)
                let srcChannels = Int(buffer.format.channelCount)
                if ch == 1 {
                    let ptr = channelData[0]
                    for i in 0..<frameCount { ringBuf.write(ptr[i]) }
                } else {
                    for i in 0..<frameCount {
                        for c in 0..<min(srcChannels, ch) { ringBuf.write(channelData[c][i]) }
                    }
                }
            }

            // Keep hwOutputChannels = 1 (forced mono) — see start() for rationale.
            hwOutputChannels = 1

            // Reconnect player — ALL connections are broken by config change.
            if let player = playerNode {
                eng.disconnectNodeOutput(player)
                if let playbackFormat = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate,
                    channels: 1
                ) {
                    eng.connect(player, to: eng.mainMixerNode, format: playbackFormat)
                }
            }

            // Update deviceSampleRate BEFORE starting drain loop so resampling is correct.
            deviceSampleRate = actualHwRate
            hwInputFormat = tapFormat
            hwInputChannels = 1

            try eng.start()

            logger.error("[AUDIO] Engine restarted after config change: \(actualHwRate, privacy: .public)Hz")

            playerNode?.play()
            logger.error("[AUDIO] PlayerNode play() after config change, isPlaying=\(self.playerNode?.isPlaying ?? false, privacy: .public)")

            // Restart drain loop — deviceSampleRate may have changed (e.g. 24kHz→48kHz),
            // so the drain loop needs to resample to the codec rate.
            drainTask?.cancel()
            startDrainLoop(hwChannels: hwInputChannels)

        } catch {
            logger.error("[AUDIO] Failed to restart after config change: \(error.localizedDescription, privacy: .public)")
        }
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

            // Register for engine configuration changes BEFORE starting the engine.
            // When the audio session category changes while the engine is running,
            // iOS reconfigures the engine and stops the playerNode silently.
            // We must restart the player to resume audio output.
            engineConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: eng,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleEngineConfigurationChange() }
            }

            // --- Capture setup ---
            let inputNode = eng.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            deviceSampleRate = inputFormat.sampleRate
            hwInputFormat = inputFormat
            hwInputChannels = Int(inputFormat.channelCount)

            let spf = samplesPerFrame
            let ch = channels
            let hwChannels = hwInputChannels
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
            // Force mono player connection. voiceChat mode uses a mono Voice
            // Processing IO unit internally — even if outputNode reports stereo
            // (e.g., speaker mode), the VP unit collapses to mono. Scheduling
            // stereo buffers through a stereo connection in this mode produces
            // silence. Force mono end-to-end for guaranteed compatibility.
            hwOutputChannels = 1

            let player = AVAudioPlayerNode()
            eng.attach(player)

            guard let playbackFormat = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
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
            startDrainLoop(hwChannels: hwChannels)

            logger.error("[AUDIO] Pipeline started: capture=\(inputFormat.sampleRate, privacy: .public)Hz \(hwChannels, privacy: .public)ch, playback=mono, codec=\(self.channels, privacy: .public)ch, frame=\(self.frameTimeMs, privacy: .public)ms, mixVol=\(eng.mainMixerNode.outputVolume, privacy: .public)")

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
        hwOutputChannels = 1
        hwInputFormat = nil
        hwInputChannels = 1

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
    /// Called by CallManager when the Telephone actor delivers decoded audio
    /// frames (via `decodedAudioCallback`). Handles buffer underruns gracefully
    /// by simply skipping frames (voice audio tolerates small gaps better than
    /// stuttering).
    ///
    /// - Parameter samples: Float32 PCM samples at the configured sample rate
    private var playCount: Int = 0

    func playDecodedAudio(_ samples: [Float]) {
        guard isActive, let player = playerNode, let eng = engine, eng.isRunning else {
            playCount += 1
            if playCount == 1 || playCount % 50 == 0 {
                logger.error("[AUDIO] DROPPED #\(self.playCount, privacy: .public): isActive=\(self.isActive, privacy: .public) engine=\(self.engine != nil, privacy: .public) running=\(self.engine?.isRunning ?? false, privacy: .public)")
            }
            return
        }
        playCount += 1

        // Always downmix to mono for playback.
        let inCh = channels
        let monoCount = samples.count / max(inCh, 1)
        var mono = [Float](repeating: 0, count: monoCount)
        if inCh > 1 {
            for i in 0..<monoCount {
                var sum: Float = 0
                for c in 0..<inCh { sum += samples[i * inCh + c] }
                mono[i] = sum / Float(inCh)
            }
        } else {
            mono = samples
        }

        let frameCount = monoCount

        // Compute peak of decoded audio for diagnostics
        let peak = mono.reduce(Float(0)) { Swift.max($0, abs($1)) }

        if playCount == 1 || playCount % 100 == 0 {
            let outputFmt = eng.outputNode.outputFormat(forBus: 0)
            logger.error("[AUDIO] Sched #\(self.playCount, privacy: .public): inSamples=\(samples.count, privacy: .public) inCh=\(inCh, privacy: .public) monoFrames=\(frameCount, privacy: .public) decodedPeak=\(peak, privacy: .public) playing=\(player.isPlaying, privacy: .public) mixVol=\(eng.mainMixerNode.outputVolume, privacy: .public) hwRate=\(outputFmt.sampleRate, privacy: .public) hwCh=\(outputFmt.channelCount, privacy: .public)")
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else { return }

        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        let dest = buffer.floatChannelData![0]
        mono.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            dest.initialize(from: base, count: frameCount)
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Capture Drain Loop

    /// Drain captured samples from the ring buffer and deliver to the callback.
    ///
    /// Runs on a background task, polling at half-frame intervals. When enough
    /// samples accumulate for a full frame, extracts them, resamples if the
    /// device rate differs from the target rate, upmixes if the hardware has
    /// fewer channels than the codec (e.g. voiceChat forces mono but codec is
    /// stereo), and invokes the callback.
    ///
    /// - Parameter hwChannels: Actual hardware channel count from inputNode format.
    ///   May be less than `channels` (e.g. voiceChat mode forces mono).
    private func startDrainLoop(hwChannels: Int) {
        // outputSpf: how many target-rate samples the codec expects per frame
        let outputSpf = samplesPerFrame * channels
        // devRate/tgtRate are captured now (we're on MainActor); the hardware
        // rate is fixed once the engine starts and won't change during the call.
        let devRate = deviceSampleRate
        let tgtRate = sampleRate
        let ch = channels

        // perChannelInputSpf: device-rate samples per channel per codec frame.
        // inputSpf: total HW samples to drain (= perChannelInputSpf × hwChannels).
        //
        // Key: use hwChannels (actual HW channels), NOT ch (codec channels).
        // voiceChat mode forces the hardware to mono even if the codec wants
        // stereo. If we used ch here, inputSpf would be 2× too large — we'd
        // accumulate 120ms of mono audio and send it as "60ms stereo", causing
        // double-speed / pitch-shifted playback on the remote peer.
        let perChannelInputSpf: Int
        if devRate > 0 && devRate != tgtRate {
            perChannelInputSpf = max(1, Int((Double(samplesPerFrame) * devRate / tgtRate).rounded()))
        } else {
            perChannelInputSpf = samplesPerFrame
        }
        let inputSpf = perChannelInputSpf * hwChannels

        let sleepNs = UInt64(frameTimeMs) * 500_000 // half frame time
        let ringBuf = captureBuffer

        logger.error("[AUDIO] DrainLoop: deviceRate=\(devRate)Hz targetRate=\(tgtRate)Hz hwCh=\(hwChannels) codecCh=\(ch) inputSpf=\(inputSpf) outputSpf=\(outputSpf)")

        drainTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let available = ringBuf.count
                if available >= inputSpf {
                    // Extract one HW-rate frame from ring buffer
                    var frame = [Float](repeating: 0, count: inputSpf)
                    for i in 0..<inputSpf {
                        frame[i] = ringBuf.read() ?? 0
                    }

                    // Produce outputSpf samples for the codec:
                    //   1. Resample HW rate → target rate if they differ.
                    //   2. Upmix HW channels → codec channels if HW has fewer.
                    //      (e.g. mono HW → stereo codec: duplicate L→R)
                    let finalFrame: [Float]
                    if hwChannels < ch {
                        // HW is mono (or lower channel count) but codec wants stereo.
                        // Step 1: resample the mono frame to target rate.
                        let monoResampled: [Float]
                        if devRate != tgtRate {
                            monoResampled = Resampler.resample(
                                frame,
                                fromRate: Int(devRate),
                                toRate: Int(tgtRate)
                            )
                        } else {
                            monoResampled = frame
                        }
                        // Step 2: duplicate mono to all codec channels (interleaved).
                        var upMixed = [Float](repeating: 0, count: monoResampled.count * ch)
                        for i in 0..<monoResampled.count {
                            for c in 0..<ch {
                                upMixed[i * ch + c] = monoResampled[i]
                            }
                        }
                        finalFrame = upMixed
                    } else if devRate != tgtRate {
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
