//
//  VoiceMessagePlayer.swift
//  ColumbaApp
//
//  Plays back a voice message `AudioAttachment`. Ported from Android
//  Columba's `VoiceMessagePlayer`:
//
//   - Codec2 -> decode the raw-frame payload to 8 kHz mono PCM, write a temp
//     `.wav` (PCM16), play with `AVAudioPlayer`.
//   - Ogg/Opus -> write the bytes to a temp `.ogg` and play with
//     `AVAudioPlayer` (AVFoundation plays Ogg/Opus natively on iOS 16+). If
//     live interop testing shows an external Ogg (Sideband) fails to play on
//     this path, an inbound granule-normalization pass is added here before
//     play (defensive; Android's normalizer was outbound-only).
//
//  A single shared instance plays one message at a time (like Android's
//  MediaPlayer singleton). Per-message state (idle / loading / playing /
//  paused / progress / duration / error) is published on the main actor;
//  progress is polled at ~250 ms. Duration + waveform metadata is cached and
//  bounded (128 entries).
//

import Foundation
import Observation
import AVFoundation
import LXSTSwift

@available(iOS 17.0, *)
@Observable
@MainActor
public final class VoiceMessagePlayer {

    public struct PlaybackState: Equatable {
        public enum Status: Equatable { case idle, loading, playing, paused, error }
        public var status: Status = .idle
        public var positionMs: Int = 0
        public var durationMs: Int = 0
        public var errorMessage: String? = nil

        public init() {}
    }

    /// Per-message playback state, keyed by a stable message id.
    public private(set) var states: [String: PlaybackState] = [:]
    /// Per-message waveform peaks (normalized 0...1, ~40 bars), cached.
    public private(set) var waveforms: [String: [Float]] = [:]

    @ObservationIgnored private var currentKey: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var tempFiles: [URL] = []
    @ObservationIgnored private let maxCacheEntries = 128

    public init() {}

    public func state(for key: String) -> PlaybackState {
        states[key] ?? PlaybackState()
    }

    public func waveform(for key: String) -> [Float]? {
        waveforms[key]
    }

    public var isPlaying: Bool {
        if let key = currentKey { return states[key]?.status == .playing }
        return false
    }

    // MARK: - Control

    /// Load metadata/waveform for a message's attachment without playing.
    public func prepare(key: String, attachment: AudioAttachment) {
        var st = states[key] ?? PlaybackState()
        if st.status == .idle || st.status == .error {
            st.status = .idle
            st.durationMs = resolveDurationMs(attachment)
            st.positionMs = 0
            states[key] = st
        }
        if waveform(for: key) == nil, let peaks = resolveWaveform(attachment) {
            cacheWaveform(key, peaks)
        }
    }

    /// Play a message. Replaces any in-flight playback.
    public func play(key: String, attachment: AudioAttachment) {
        stopCurrent()
        currentKey = key
        var st = states[key] ?? PlaybackState()
        st.status = .loading
        st.errorMessage = nil
        st.positionMs = 0
        st.durationMs = resolveDurationMs(attachment)
        states[key] = st
        if waveform(for: key) == nil, let peaks = resolveWaveform(attachment) {
            cacheWaveform(key, peaks)
        }
        Task { [weak self] in
            do {
                try await self?.startPlayback(key: key, attachment: attachment)
            } catch {
                DiagLog.log("[VOICE-PLAY] ERROR key=\(key.prefix(8)) \(error.localizedDescription)")
                self?.markError(key, error.localizedDescription)
            }
        }
    }

    public func pause() {
        guard let key = currentKey, let player else { return }
        player.pause()
        var st = states[key] ?? PlaybackState()
        st.status = .paused
        st.positionMs = Int(player.currentTime * 1_000)
        states[key] = st
    }

    public func resume() {
        guard let key = currentKey, let player else { return }
        player.play()
        states[key]?.status = .playing
        startProgressPolling()
    }

    public func togglePlay(key: String, attachment: AudioAttachment) {
        if currentKey == key {
            if states[key]?.status == .playing { pause() }
            else if states[key]?.status == .paused { resume() }
        } else {
            play(key: key, attachment: attachment)
        }
    }

    public func stopCurrent() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        if let key = currentKey {
            var st = states[key] ?? PlaybackState()
            st.status = .idle
            st.positionMs = 0
            states[key] = st
        }
        currentKey = nil
    }

    // MARK: - Playback start (off the main-actor hot path)

    private func startPlayback(key: String, attachment: AudioAttachment) async throws {
        DiagLog.log("[VOICE-PLAY] start key=\(key.prefix(8)) mode=0x\(String(format: "%02x", attachment.mode.rawValue)) bytes=\(attachment.bytes.count)")
        let url = try renderToTempFile(attachment)
        tempFiles.append(url)
        let filePlayer = try AVAudioPlayer(contentsOf: url)
        let ready = filePlayer.prepareToPlay()
        DiagLog.log("[VOICE-PLAY] prepareToPlay=\(ready) duration=\(filePlayer.duration)")
        guard ready else {
            DiagLog.log("[VOICE-PLAY] UNPLAYABLE url=\(url.lastPathComponent)")
            throw PlayerError.unplayable
        }
        filePlayer.numberOfLoops = 0
        filePlayer.volume = 1.0
        player = filePlayer
        filePlayer.play()
        var st = states[key] ?? PlaybackState()
        st.status = .playing
        if st.durationMs == 0 { st.durationMs = Int((filePlayer.duration * 1_000).rounded()) }
        states[key] = st
        DiagLog.log("[VOICE-PLAY] PLAYING durationMs=\(st.durationMs)")
        startProgressPolling()
    }

    private func startProgressPolling() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let key = self.currentKey, let player = self.player else { return }
                var st = self.states[key] ?? PlaybackState()
                st.positionMs = Int((player.currentTime * 1_000).rounded())
                self.states[key] = st
                if !player.isPlaying {
                    self.states[key]?.status = .idle
                    self.stopCurrent()
                    return
                }
            }
        }
    }

    private func markError(_ key: String, _ message: String) {
        stopCurrent()
        var st = states[key] ?? PlaybackState()
        st.status = .error
        st.errorMessage = message
        states[key] = st
    }

    // MARK: - Rendering

    /// Materialize the attachment as a temp file the player can open.
    private func renderToTempFile(_ attachment: AudioAttachment) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-voice-play", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if attachment.mode.isCodec2 {
            let decoded = try Codec2RawFile.decodePayload(attachment.bytes, mode: attachment.mode)
            let wav = dir.appendingPathComponent("voice_\(UUID().uuidString).wav")
            try Codec2RawFile.writeWave(decoded, to: wav)
            return wav
        }
        // Ogg/Opus: AVFoundation plays .ogg directly.
        let ogg = dir.appendingPathComponent("voice_\(UUID().uuidString).ogg")
        try attachment.bytes.write(to: ogg)
        return ogg
    }

    // MARK: - Metadata

    private func resolveDurationMs(_ attachment: AudioAttachment) -> Int {
        if let existing = states[currentKey ?? ""]?.durationMs, existing > 0 { return existing }
        if attachment.mode.isCodec2 {
            return (attachment.durationMs ?? 0)
        }
        if let meta = OggOpusMetadataReader.read([UInt8](attachment.bytes)) {
            return meta.durationMs
        }
        return attachment.durationMs ?? 0
    }

    private func resolveWaveform(_ attachment: AudioAttachment) -> [Float]? {
        let bars = 40
        guard attachment.mode.isCodec2 else {
            // Ogg: decoding the full file for peaks is heavy; use a neutral
            // filled waveform (never block playback on it).
            return Array(repeating: 0.5, count: bars)
        }
        guard let decoded = try? Codec2RawFile.decodePayload(attachment.bytes, mode: attachment.mode) else {
            return Array(repeating: 0.5, count: bars)
        }
        return peaks(from: decoded.samples, bars: bars)
    }

    private func cacheWaveform(_ key: String, _ peaks: [Float]) {
        if waveforms.count >= maxCacheEntries {
            // Drop the oldest inserted key (FIFO approximation).
            if let oldest = waveforms.keys.first { waveforms[oldest] = nil }
        }
        waveforms[key] = peaks
    }

    private func peaks(from pcm: [Int16], bars: Int) -> [Float] {
        guard !pcm.isEmpty else { return Array(repeating: 0.0, count: bars) }
        let chunk = max(1, pcm.count / bars)
        var out = [Float](); out.reserveCapacity(bars)
        var i = 0
        while i < pcm.count && out.count < bars {
            var maxAbs: Int16 = 0
            let end = min(i + chunk, pcm.count)
            for j in i..<end {
                let a = abs(Int32(pcm[j]))
                if a > Int32(maxAbs) { maxAbs = Int16(clamping: a) }
            }
            out.append(Float(Int(maxAbs)) / 32_768.0)
            i = end
        }
        while out.count < bars { out.append(0) }
        return out
    }

    public func tearDown() {
        stopCurrent()
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles.removeAll()
        states.removeAll()
        waveforms.removeAll()
    }

    private enum PlayerError: Error { case unplayable }
}
