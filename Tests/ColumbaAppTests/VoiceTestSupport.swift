//
//  VoiceTestSupport.swift
//  ColumbaAppTests
//
//  Shared helpers for the voice-message XCTest suites: deterministic PCM, a
//  valid 48 kHz Opus TOC packet, an Ogg page walker (structure + CRC checks,
//  independent of the writer's own bookkeeping), a bounded fake audio capture
//  for the recorder state-machine tests, and a MainActor state poller.
//

import XCTest
import Foundation
import LXSTSwift
@testable import ColumbaApp

enum VoiceTestSupport {

    /// `count` mono int16 samples of a 440 Hz sine at 8 kHz.
    static func pcm(count: Int, rate: Int = 8_000) -> [Int16] {
        (0..<count).map { i in
            Int16((sin(2 * .pi * 440 * Double(i) / Double(rate))) * 12_000)
        }
    }

    /// A valid Opus packet TOC byte (48 kHz, 20 ms, single frame = 960
    /// samples at 48 kHz) + filler payload. `0x98`: s=1 (48k), code=3 (20ms),
    /// c=0 (one frame). Returns 960 from `OggOpusGranule.packetSamples48k`.
    static func opusPacket(toc: UInt8 = 0x98, size: Int = 40) -> [UInt8] {
        [toc] + [UInt8](repeating: 0x11, count: size - 1)
    }

    // MARK: - Ogg page walking

    struct OggPage {
        let granule: Int64
        let payload: [UInt8]
        let pageStart: Int
    }

    /// Walk a byte stream's Ogg pages. Returns nil when any page is malformed
    /// or the stream does not terminate cleanly on a page boundary.
    static func oggPages(_ data: [UInt8]) -> [OggPage]? {
        guard data.count >= 27,
              data[0] == 0x4F, data[1] == 0x67, data[2] == 0x67, data[3] == 0x53
        else { return nil }
        var pages: [OggPage] = []
        var off = 0
        while off < data.count {
            guard off + 27 <= data.count,
                  data[off] == 0x4F, data[off + 1] == 0x67, data[off + 2] == 0x67,
                  data[off + 3] == 0x53
            else { return nil }
            let seg = Int(data[off + 26])
            var payloadSize = 0
            for i in 0..<seg { payloadSize += Int(data[off + 27 + i]) }
            let end = off + 27 + seg + payloadSize
            guard end <= data.count else { return nil }
            var g: Int64 = 0
            for i in 0..<8 { g |= Int64(UInt64(data[off + 6 + i])) << (i * 8) }
            let payload = Array(data[(off + 27 + seg)..<end])
            pages.append(OggPage(granule: g, payload: payload, pageStart: off))
            off = end
        }
        return pages
    }

    /// True when the page's stored Ogg CRC (bytes 22..25) matches a
    /// recomputation over the page with the stored field zeroed.
    static func oggPageCRCValid(_ data: [UInt8], pageStart: Int, pageEnd: Int) -> Bool {
        let stored = UInt32(data[pageStart + 22])
            | (UInt32(data[pageStart + 23]) << 8)
            | (UInt32(data[pageStart + 24]) << 16)
            | (UInt32(data[pageStart + 25]) << 24)
        let computed = OggOpusGranule.oggChecksum(data, pageStart, pageEnd,
                                                  zeroStoredChecksum: true)
        return stored == computed
    }

    /// Poll (bounded) for a file to (not) exist. Async so the MainActor stays
    /// free to run the recorder's completion task.
    static func awaitFile(at url: URL, exists: Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) == exists { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return FileManager.default.fileExists(atPath: url.path) == exists
    }

    /// Poll (bounded) until the fake capture's buffer is fully drained by the
    /// capture thread. Call this BEFORE `recorder.stop()` in tests: the fake
    /// capture serves its whole finite buffer within a few milliseconds, so
    /// stopping the instant the output file appears can race the encode loop
    /// (0-1 frames written -> "no audio" / wrong frame count). Production is
    /// unaffected: a real microphone never "drains" - the loop spins on
    /// read()==0 until the latch flips.
    static func awaitDrained(_ capture: FakeVoiceCapture, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while capture.remaining > 0 {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// Poll (bounded) until the file's on-disk size stops changing (two reads
    /// `settle` apart are equal and non-zero). Call AFTER the capture buffer is
    /// drained: the drain guarantees all samples are read, but the final
    /// read-batch's frames are encoded+written *after* the read that drained,
    /// so a drain-only stop can drop that last batch (count lands ~6 frames low).
    /// Waiting for the size to settle waits for the loop to actually stop
    /// writing. Deterministic and independent of the exact final frame count.
    static func awaitFileSettled(at url: URL, timeout: TimeInterval = 5,
                                 settle: TimeInterval = 0.05) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        while Date() < deadline {
            let s = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if s > 0 && s == last { return true }
            last = s
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        }
        return false
    }
}

/// Bounded, thread-safe fake capture. `read` returns up to `capacity` mono
/// samples from a pre-generated buffer (0 once exhausted); `start` may throw.
final class FakeVoiceCapture: VoicePcmCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Int16]
    private var startError: Error?
    var closeCount = 0
    var stopCount = 0
    let support: Bool
    let rate: Int

    /// Samples still queued for `read`. Tests use this to wait for the capture
    /// thread to fully drain a finite fake buffer before stopping the recorder
    /// (a file-exists wait alone is not enough: the fake returns its whole
    /// buffer in milliseconds, so the loop could still be mid-encode).
    var remaining: Int { lock.lock(); defer { lock.unlock() }; return queue.count }

    init(samples: [Int16] = [], rate: Int = 8_000, startError: Error? = nil,
         supported: Bool = true) {
        self.queue = samples
        self.rate = rate
        self.startError = startError
        self.support = supported
    }

    var isSupported: Bool { support }
    var sampleRate: Int { rate }

    func start() throws {
        if let startError { throw startError }
    }

    func read(into buffer: inout [Int16], capacity: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = min(capacity, queue.count)
        for i in 0..<n { buffer[i] = queue.removeFirst() }
        return n
    }

    func stop() {
        lock.lock(); stopCount += 1; lock.unlock()
    }

    func close() {
        lock.lock(); closeCount += 1; lock.unlock()
    }
}

final class FakeVoiceCaptureFactory: VoicePcmCaptureFactory, @unchecked Sendable {
    let samples: [Int16]
    let rate: Int
    let startError: Error?
    let supported: Bool
    private(set) var madeCaptures: [FakeVoiceCapture] = []
    private let lock = NSLock()

    init(samples: [Int16] = [], rate: Int = 8_000, startError: Error? = nil,
         supported: Bool = true) {
        self.samples = samples
        self.rate = rate
        self.startError = startError
        self.supported = supported
    }

    func makeCapture(channels: Int, sampleRateHint: Int) -> VoicePcmCapture {
        let cap = FakeVoiceCapture(samples: samples, rate: rate,
                                   startError: startError, supported: supported)
        lock.lock(); madeCaptures.append(cap); lock.unlock()
        return cap
    }
}

/// Poll the recorder's state (MainActor) until it reaches `done`, with a
/// bounded timeout. Runs while the MainActor is free to process the capture
/// loop's completion task.
@MainActor
func waitForRecorderState(
    _ recorder: VoiceMessageRecorder,
    timeout: TimeInterval = 5,
    done: @escaping (VoiceRecorderState) -> Bool
) async -> VoiceRecorderState {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(recorder.state) {
        if Date() > deadline { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return recorder.state
}

@MainActor
func waitForPlayerStatus(
    _ player: VoiceMessagePlayer,
    key: String,
    timeout: TimeInterval = 10,
    done: @escaping (VoiceMessagePlayer.PlaybackState.Status) -> Bool
) async -> VoiceMessagePlayer.PlaybackState.Status {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(player.state(for: key).status) {
        if Date() > deadline { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return player.state(for: key).status
}
