// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  AudioIO.swift
//  LXSTSwift
//
//  Real-time audio I/O using AVAudioEngine for iOS/macOS.
//  Captures microphone input and plays back decoded audio.
//
//  Guarded by #if canImport(AVFoundation) for SPM compatibility.
//

#if canImport(AVFoundation)
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.lxst.swift", category: "AudioIO")

/// Real-time audio I/O using AVAudioEngine.
///
/// Captures microphone audio via input tap and plays decoded audio
/// via AVAudioPlayerNode. Uses a lock-free ring buffer between
/// the real-time audio callback and the async actor world.
///
/// Matches Python `LXST.Platforms.darwin.soundcard` but uses the
/// high-level AVAudioEngine API instead of raw CoreAudio.
public actor AudioIO {

    // MARK: - Configuration

    /// Audio session configuration for voice calls.
    public struct Config: Sendable {
        public let sampleRate: Double
        public let channels: Int
        public let frameTimeMs: Int
        public let ioBufferDuration: TimeInterval

        public init(
            sampleRate: Double = 48000,
            channels: Int = 1,
            frameTimeMs: Int = 20,
            ioBufferDuration: TimeInterval = 0.005
        ) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.frameTimeMs = frameTimeMs
            self.ioBufferDuration = ioBufferDuration
        }

        /// Create from a TelephonyProfile.
        public init(profile: TelephonyProfile) {
            switch profile.codecType {
            case .opus:
                let opus = profile.opusProfile!
                self.sampleRate = Double(opus.sampleRate)
                self.channels = opus.channels
            case .codec2:
                self.sampleRate = 8000
                self.channels = 1
            default:
                self.sampleRate = 48000
                self.channels = 1
            }
            self.frameTimeMs = profile.frameTimeMs
            // Lower IO buffer for low-latency profiles
            self.ioBufferDuration = profile.frameTimeMs <= 20 ? 0.005 : 0.01
        }

        /// Samples per frame (per channel).
        public var samplesPerFrame: Int {
            Int(sampleRate) * frameTimeMs / 1000
        }
    }

    // MARK: - State

    private let config: Config
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var isCapturing = false
    private var isPlaying = false

    /// Ring buffer for captured audio (real-time thread → async world).
    private var captureBuffer: RingBuffer<Float>

    /// Callback for captured audio frames.
    private var captureCallback: (@Sendable ([Float]) async -> Void)?

    /// The device sample rate (may differ from config).
    private var deviceSampleRate: Double = 48000

    public init(config: Config) {
        self.config = config
        // Ring buffer holds ~200ms of audio
        let ringSize = Int(config.sampleRate) * config.channels / 5
        self.captureBuffer = RingBuffer(capacity: max(ringSize, 4096))
    }

    // MARK: - Capture

    /// Set the callback for captured microphone frames.
    ///
    /// Called with float samples at the configured sample rate and channel count.
    public func setCaptureCallback(
        _ callback: @escaping @Sendable ([Float]) async -> Void
    ) {
        self.captureCallback = callback
    }

    /// Start capturing audio from the microphone.
    public func startCapture() throws {
        guard !isCapturing else { return }

        #if os(iOS)
        try configureAudioSession()
        #endif

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        deviceSampleRate = inputFormat.sampleRate

        let samplesPerFrame = config.samplesPerFrame
        let channels = config.channels
        let captureBuffer = self.captureBuffer

        // Install tap on input node
        // The tap callback runs on a real-time thread — NO async/await here
        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(samplesPerFrame),
            format: inputFormat
        ) { [weak captureBuffer] buffer, _ in
            guard let captureBuffer = captureBuffer,
                  let channelData = buffer.floatChannelData else { return }

            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)

            // Extract mono or interleaved samples
            if channels == 1 {
                // Take first channel only
                let ptr = channelData[0]
                for i in 0..<frameCount {
                    captureBuffer.write(ptr[i])
                }
            } else {
                // Interleave channels
                for i in 0..<frameCount {
                    for ch in 0..<min(channelCount, channels) {
                        captureBuffer.write(channelData[ch][i])
                    }
                }
            }
        }

        try engine.start()
        isCapturing = true
        logger.info("[AUDIO-IO] Capture started at \(inputFormat.sampleRate)Hz")

        // Start drain loop
        Task { [weak self] in
            await self?.drainCaptureBuffer()
        }
    }

    /// Stop capturing audio.
    public func stopCapture() {
        guard isCapturing else { return }
        engine?.inputNode.removeTap(onBus: 0)
        isCapturing = false
        logger.info("[AUDIO-IO] Capture stopped")
    }

    /// Drain captured samples from the ring buffer and deliver to callback.
    private func drainCaptureBuffer() async {
        let samplesPerFrame = config.samplesPerFrame * config.channels
        let sleepNs = UInt64(config.frameTimeMs) * 500_000 // half frame time

        while isCapturing {
            let available = captureBuffer.count
            if available >= samplesPerFrame {
                var frame = [Float](repeating: 0, count: samplesPerFrame)
                for i in 0..<samplesPerFrame {
                    frame[i] = captureBuffer.read() ?? 0
                }

                // Resample if device rate differs from config rate
                let finalFrame: [Float]
                if deviceSampleRate != config.sampleRate {
                    finalFrame = Resampler.resample(
                        frame,
                        fromRate: Int(deviceSampleRate),
                        toRate: Int(config.sampleRate)
                    )
                } else {
                    finalFrame = frame
                }

                await captureCallback?(finalFrame)
            } else {
                try? await Task.sleep(nanoseconds: sleepNs)
            }
        }
    }

    // MARK: - Playback

    /// Start the playback engine.
    public func startPlayback() throws {
        guard !isPlaying else { return }

        if engine == nil {
            #if os(iOS)
            try configureAudioSession()
            #endif
            let eng = AVAudioEngine()
            self.engine = eng
        }

        guard let engine = engine else { return }

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        let format = AVAudioFormat(
            standardFormatWithSampleRate: config.sampleRate,
            channels: AVAudioChannelCount(config.channels)
        )!

        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        if !engine.isRunning {
            try engine.start()
        }

        playerNode.play()
        self.playerNode = playerNode
        isPlaying = true
        logger.info("[AUDIO-IO] Playback started")
    }

    /// Play decoded float samples through the speaker.
    ///
    /// - Parameter samples: Float samples at the configured sample rate
    public func play(_ samples: [Float]) {
        guard isPlaying, let playerNode = playerNode else { return }

        let format = AVAudioFormat(
            standardFormatWithSampleRate: config.sampleRate,
            channels: AVAudioChannelCount(config.channels)
        )!

        let frameCount = samples.count / config.channels
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        if config.channels == 1 {
            // Mono: copy directly
            let dest = buffer.floatChannelData![0]
            samples.withUnsafeBufferPointer { src in
                dest.initialize(from: src.baseAddress!, count: frameCount)
            }
        } else {
            // Deinterleave into separate channel buffers
            for ch in 0..<config.channels {
                let dest = buffer.floatChannelData![ch]
                for i in 0..<frameCount {
                    dest[i] = samples[i * config.channels + ch]
                }
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Stop playback.
    public func stopPlayback() {
        guard isPlaying else { return }
        playerNode?.stop()
        isPlaying = false
        logger.info("[AUDIO-IO] Playback stopped")
    }

    // MARK: - Full Duplex

    /// Start both capture and playback.
    public func start() throws {
        try startCapture()
        try startPlayback()
    }

    /// Stop both capture and playback.
    public func stop() {
        stopCapture()
        stopPlayback()
        engine?.stop()
        engine = nil
        playerNode = nil
    }

    /// Whether audio is currently active.
    public var isActive: Bool {
        isCapturing || isPlaying
    }

    // MARK: - Audio Session (iOS)

    #if os(iOS)
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setPreferredIOBufferDuration(config.ioBufferDuration)
        try session.setPreferredSampleRate(config.sampleRate)
        try session.setActive(true)
        logger.info("[AUDIO-IO] Audio session configured for voice chat")
    }
    #endif
}

// MARK: - Lock-Free Ring Buffer

/// Simple lock-free SPSC (single-producer, single-consumer) ring buffer.
///
/// Used to transfer audio samples from the real-time audio thread
/// to the async actor world without locks or memory allocation.
final class RingBuffer<T>: @unchecked Sendable {
    private let buffer: UnsafeMutableBufferPointer<T>
    private let capacity: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        self.buffer = UnsafeMutableBufferPointer(start: ptr, count: capacity)
    }

    deinit {
        buffer.baseAddress?.deallocate()
    }

    /// Number of available samples to read.
    var count: Int {
        let w = writeIndex
        let r = readIndex
        if w >= r {
            return w - r
        } else {
            return capacity - r + w
        }
    }

    /// Write a single value. Overwrites oldest if full.
    func write(_ value: T) {
        buffer[writeIndex] = value
        writeIndex = (writeIndex + 1) % capacity
    }

    /// Read a single value. Returns nil if empty.
    func read() -> T? {
        guard count > 0 else { return nil }
        let value = buffer[readIndex]
        readIndex = (readIndex + 1) % capacity
        return value
    }
}

#endif // canImport(AVFoundation)
