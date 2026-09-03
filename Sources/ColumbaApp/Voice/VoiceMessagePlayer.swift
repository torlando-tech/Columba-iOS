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
    @ObservationIgnored private var waveformInFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var tempFiles: [URL] = []
    @ObservationIgnored private var isTornDown = false
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
    /// Safe to call repeatedly (onAppear + play tap): waveform computation is
    /// single-flighted per key and cached, so repeated calls are no-ops.
    public func prepare(key: String, attachment: AudioAttachment) {
        var st = states[key] ?? PlaybackState()
        if st.status == .idle || st.status == .error {
            st.status = .idle
            st.durationMs = resolveDurationMs(attachment)
            st.positionMs = 0
            states[key] = st
        }
        prepareWaveform(key: key, attachment: attachment)
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
        prepareWaveform(key: key, attachment: attachment)
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

        // The audio session must be in a PLAYBACK state before play(): the
        // voice recorder sets it to .playAndRecord and deactivates it, and a
        // .playAndRecord session (a) is silenced by the mute switch and
        // (b) can default toward the earpiece - so AVAudioPlayer reports
        // isPlaying=true but is inaudible. .playback routes to the speaker
        // (or connected headphones) and ignores the mute switch. Guard
        // against an active call (mode .voiceChat, set by CallKitManager):
        // reconfiguring the category there would drop the mic and break the
        // call, so leave the session alone in that case (playing a voice
        // message mid-call is a rare edge case).
        let session = AVAudioSession.sharedInstance()
        if session.mode != .voiceChat {
            do {
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true, options: [])
            } catch {
                DiagLog.log("[VOICE-PLAY] session setup failed: \(error.localizedDescription)")
            }
        }
        logSessionState(context: "pre-play")

        let filePlayer = try AVAudioPlayer(contentsOf: url)
        filePlayer.numberOfLoops = 0
        filePlayer.volume = 1.0
        // prepareToPlay() is NOT a reliable gate for Ogg/Opus: AVFoundation's
        // format reader returns false for streaming formats even when play()
        // works (it still reads duration correctly, as seen in diag). Gate on
        // the actual play() result (isPlaying) instead, with a brief poll for
        // the first decode buffer.
        _ = filePlayer.prepareToPlay()
        filePlayer.play()
        var playing = filePlayer.isPlaying
        if !playing {
            // First buffer may not be decoded synchronously for a streaming
            // format; give it a short, bounded window before declaring defeat.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if filePlayer.isPlaying { playing = true; break }
            }
        }
        DiagLog.log("[VOICE-PLAY] isPlaying=\(playing) duration=\(filePlayer.duration)")
        guard playing else {
            DiagLog.log("[VOICE-PLAY] UNPLAYABLE url=\(url.lastPathComponent)")
            throw PlayerError.unplayable
        }
        logSessionState(context: "playing")
        player = filePlayer
        var st = states[key] ?? PlaybackState()
        st.status = .playing
        if st.durationMs == 0 { st.durationMs = Int((filePlayer.duration * 1_000).rounded()) }
        states[key] = st
        DiagLog.log("[VOICE-PLAY] PLAYING durationMs=\(st.durationMs)")
        startProgressPolling()
    }

    /// Privacy-safe audio-session snapshot (category/route/volume only, no PII)
    /// for diagnosing audible-playback issues on the WiFi-only device.
    private func logSessionState(context: String) {
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute
        let outputs = route.outputs.map { "type=\($0.portType.rawValue)" }.joined(separator: ",")
        DiagLog.log("[VOICE-SESSION] \(context) category=\(s.category.rawValue) mode=\(s.mode.rawValue) vol=\(String(format: "%.2f", s.outputVolume)) route=[\(outputs)]")
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
        // Ogg/Opus: AVFoundation plays .ogg directly - EXCEPT it rejects the
        // multi-packet-per-page layout that Sideband's PyOgg emits (see
        // OggOpusInboundNormalizer). Normalize first; if the bytes are not a
        // decodable Ogg stream at all, fall back to the raw bytes so the
        // existing unplayable path still applies (never worse than before).
        let raw = [UInt8](attachment.bytes)
        let normalized = (try? OggOpusInboundNormalizer.normalize(raw))?.bytes
        let ogg = dir.appendingPathComponent("voice_\(UUID().uuidString).ogg")
        try Data(normalized ?? raw).write(to: ogg)
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

    /// Compute (or reuse the cached) waveform for a message.
    ///
    /// - Codec2: the payload is a small raw-frame concatenation; decode
    ///   synchronously so the peaks are cached before the first play (the
    ///   Codec2 decode is a few ms at most).
    /// - Ogg/Opus: decoding the full file for peaks is heavier and uses
    ///   AVFoundation's file decoder (reliable on device; on the simulator it
    ///   may legitimately fail - that's fine). Compute on a background task,
    ///   single-flighted per key (Android's `prepareMetadata` does the same);
    ///   until it lands - or if it fails - the views render the neutral
    ///   placeholder via `waveform(for:) ?? VoiceWaveform.placeholder()`.
    ///   Playback never waits on it.
    private func prepareWaveform(key: String, attachment: AudioAttachment) {
        if waveform(for: key) != nil { return }
        if attachment.mode.isCodec2 {
            guard let peaks = codec2Peaks(attachment) else { return }
            cacheWaveform(key, peaks)
            return
        }
        guard waveformInFlight[key] == nil else { return }
        let bytes = attachment.bytes
        let task = Task { [weak self] in
            // Decode + bucket off the main actor; publish the peaks (if any)
            // back on the main actor.
            let peaks = await Task.detached(priority: .utility) {
                OggOpusWaveform.realWaveform(from: bytes)
            }.value
            self?.cacheWaveformIfCurrent(key: key, peaks: peaks)
        }
        waveformInFlight[key] = task
    }

    /// Cache decoded Ogg peaks and clear the in-flight slot (called from the
    /// prepareWaveform task, on the main actor). A nil decode result is a
    /// non-fatal fail-open: the slot is still cleared and the views keep the
    /// neutral placeholder.
    private func cacheWaveformIfCurrent(key: String, peaks: [Float]?) {
        waveformInFlight[key] = nil
        if let peaks {
            cacheWaveform(key, peaks)
        }
    }

    /// Synchronous Codec2 peaks (pure decode + peak-max, as before).
    private func codec2Peaks(_ attachment: AudioAttachment) -> [Float]? {
        let bars = OggOpusWaveform.bars
        guard let decoded = try? Codec2RawFile.decodePayload(attachment.bytes, mode: attachment.mode) else {
            return nil
        }
        return peaks(from: decoded.samples, bars: bars)
    }

    private func cacheWaveform(_ key: String, _ peaks: [Float]) {
        guard !isTornDown else { return }
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
        // Cancel any in-flight waveform decodes so a late result cannot
        // repopulate the (about-to-be-cleared) cache.
        for (_, task) in waveformInFlight { task.cancel() }
        waveformInFlight.removeAll()
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles.removeAll()
        states.removeAll()
        waveforms.removeAll()
        isTornDown = true
    }

    private enum PlayerError: Error { case unplayable }
}
