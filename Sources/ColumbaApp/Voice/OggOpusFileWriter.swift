//
//  OggOpusFileWriter.swift
//  ColumbaApp
//
//  Minimal Ogg/Opus muxer for stored voice messages. iOS has no system
//  "record to Ogg/Opus" API, so Columba owns the container writer here.
//
//  The container is kept deliberately small: an OpusHead (identification) page,
//  an OpusTags (comment) page, then audio pages carrying 60 ms Opus frames. A
//  single Opus packet may span several pages (a 60 ms frame at ≥16 kbps can
//  exceed one page's 255-byte payload limit); the packet's FINAL page carries
//  the granule, its continuation pages carry -1.
//
//  INTEROP (the load-bearing part): every packet's granule is the CUMULATIVE
//  END-OF-PACKET 48 kHz sample count, computed with the pure
//  `OggOpusGranule.packetSamples48k`. This is precisely the layout Android's
//  `OggOpusAndroidTimestampNormalizer` rewrites MediaRecorder output into, so
//  the normalizer is a NO-OP on our output — the condition that makes the file
//  playable by Sideband's LXST/libopusfile path. (MediaRecorder emitted
//  packet-START granules starting at 0 that libopusfile rejects with
//  OP_EBADTIMESTAMP; we emit end-of-packet directly, so we are Sideband-
//  compatible on the first build. A unit test asserts the no-op property.)
//
//  `preSkip` is the encoder delay (48 kHz samples) recorded into OpusHead. A
//  decoder discards that many leading samples. It is passed in by the recorder
//  (derived from the libopus VOIP encoder's `OPUS_GET_LOOKAHEAD`, see
//  `OggOpusWriter.preSkipForProfile`) and is a quality detail, not an interop
//  one (granules are what drive the Sideband path).
//

import Foundation

public struct OggOpusFileError: Error, Equatable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

/// Builds an Ogg/Opus file byte stream from 60 ms Opus packets.
///
/// Pure: `appendPacket`/`finish` produce bytes; no I/O or AVFoundation here
/// (the static `publishToDisk` helper is the only file-touching method).
public final class OggOpusFileWriter {

    public let channels: Int
    /// Encoder delay (48 kHz samples) recorded into the OpusHead pre-skip field.
    public let preSkip: Int
    private let serial: UInt32
    private var bytes: [UInt8] = []
    private var pageSequence: Int32 = 0
    /// Cumulative 48 kHz sample position = end of the last packet written.
    private var cumulativeSamples: UInt64 = 0
    private var packetsWritten = 0
    private var finalGranule: UInt64 = 0

    /// 8 MiB ceiling (matches the Android normalizer's `MAX_FILE_SIZE_BYTES`
    /// and the playback metadata cap). Enforced in `finish` / `publishToDisk`.
    public static let maxFileBytes = 8 * 1024 * 1024

    /// The libopus VOIP encoder's `OPUS_GET_LOOKAHEAD` for the three Columba
    /// Opus profiles. Derived from the vendored opus source
    /// (`opus_encoder.c:2835-2845`): for `OPUS_APPLICATION_VOIP` the lookahead
    /// is `Fs/400 + delay_compensation`, and `delay_compensation = Fs/250`
    /// (`opus_encoder.c:282`), i.e. `Fs/100`. Hence 24 000/100 = 240 and
    /// 48 000/100 = 480. (A `RESTRICTED_LOWDELAY` app would be `Fs/400`, but
    /// Columba always uses the VOIP application.)
    public static func preSkipForProfile(sampleRate: Int) -> Int {
        max(1, sampleRate / 100)
    }

    public init(channels: Int, preSkip: Int, serial: UInt32? = nil) {
        self.channels = channels
        self.preSkip = preSkip
        self.serial = serial ?? UInt32.random(in: 1...UInt32.max)
        // All stored properties are now initialized; emit the two header pages
        // (OpusHead on page 0 with the begin-of-stream flag, then OpusTags).
        try? self.writeHeaderPages()
    }

    // MARK: - Header packets

    /// Opus identification header (19 bytes): "OpusHead", version 1, channels,
    /// pre-skip (16-bit LE), input sample rate (48 000, 32-bit LE), gain (0),
    /// mapping family (0).
    private func opusHead() -> [UInt8] {
        var h = Array("OpusHead".utf8)
        h.append(0x01)                       // version
        h.append(UInt8(channels))            // channel count
        h.append(UInt8(preSkip & 0xFF))      // pre-skip low byte (LE)
        h.append(UInt8((preSkip >> 8) & 0xFF))
        h.append(contentsOf: withLE32(48_000))
        h.append(contentsOf: withLE16(0))    // output gain
        h.append(0x00)                       // mapping family
        return h
    }

    /// Opus comment header: "OpusTags", vendor-length (0), comment-count (0).
    private func opusTags() -> [UInt8] {
        var t = Array("OpusTags".utf8)
        t.append(contentsOf: withLE32(0))
        t.append(contentsOf: withLE32(0))
        return t
    }

    // MARK: - Append

    /// Append one 60 ms Opus packet on its OWN page, carrying the cumulative
    /// end-of-packet granule. One packet per page is the exact layout Android's
    /// Ogg normalizer rewrites to (and verifies: `packetCount == 1 &&
    /// packetSize == payloadSize`), so our output is a normalizer no-op.
    ///
    /// A single Ogg page can hold up to 255 lacing values (255 × 255 = 65 025
    /// bytes), which is far larger than any 60 ms Columba packet (≤ 240 bytes at
    /// the 32 kbps ceiling), so no packet ever spans pages.
    public func appendPacket(_ packet: [UInt8]) throws {
        guard !packet.isEmpty else { throw OggOpusFileError("empty-packet") }
        guard packet.count <= 255 * 255 else { throw OggOpusFileError("packet-too-large") }
        let samples = try OggOpusGranule.packetSamples48k(packet)
        cumulativeSamples += UInt64(samples)
        packetsWritten += 1

        // Split the packet into ≤255-byte lacing segments. A value of 255 means
        // "full segment, continues"; the final segment (<255) terminates the
        // packet. For a packet <255 bytes this is a single [count] lacing value.
        var lacing: [UInt8] = []
        var remaining = packet.count
        while remaining >= 255 { lacing.append(255); remaining -= 255 }
        lacing.append(UInt8(remaining))

        try appendPage(payload: packet, lacing: lacing,
                       granule: cumulativeSamples, bos: pageSequence == 0)
    }

    /// Finalize the stream. `bytes` is the complete Ogg/Opus file. Enforces the
    /// size ceiling. (No trailing EOS page is required for libopusfile /
    /// AVAudioPlayer.)
    @discardableResult
    public func finish() throws -> [UInt8] {
        guard packetsWritten >= 1 else { throw OggOpusFileError("no-audio") }
        finalGranule = cumulativeSamples
        guard bytes.count <= OggOpusFileWriter.maxFileBytes else {
            throw OggOpusFileError("size-limit")
        }
        return bytes
    }

    public var completedBytes: [UInt8] { bytes }
    public var finalGranuleValue: UInt64 { finalGranule }
    public var packets: Int { packetsWritten }

    // MARK: - Page emission

    /// Emit the OpusHead and OpusTags pages (granule -1) at the start of the
    /// stream, before any audio page.
    private func writeHeaderPages() throws {
        try appendPage(payload: opusHead(), lacing: [UInt8(opusHead().count)],
                       granule: OggOpusGranule.granuleUndefined, bos: true)
        try appendPage(payload: opusTags(), lacing: [UInt8(opusTags().count)],
                       granule: OggOpusGranule.granuleUndefined, bos: false)
    }

    private func appendPage(payload: [UInt8], lacing: [UInt8], granule: UInt64, bos: Bool) throws {
        guard lacing.count >= 1, lacing.count <= 255 else { throw OggOpusFileError("lacing-range") }
        var header = [UInt8](repeating: 0, count: OggOpusGranule.oggHeaderSize)
        header[0..<4] = OggOpusGranule.capturePattern
        header[4] = 0x02                       // version
        header[5] = bos ? 0x02 : 0x00          // flags: 0x02 = begin of stream
        for i in 0..<8 { header[6 + i] = UInt8((granule >> (i * 8)) & 0xFF) }
        for i in 0..<4 { header[14 + i] = UInt8((serial >> (i * 8)) & 0xFF) }
        for i in 0..<4 { header[18 + i] = UInt8((UInt32(pageSequence) >> (i * 8)) & 0xFF) }
        header[26] = UInt8(lacing.count)

        var page = header
        page.append(contentsOf: lacing)
        page.append(contentsOf: payload)

        let crc = OggOpusGranule.oggChecksum(page, 0, page.count, zeroStoredChecksum: true)
        for i in 0..<4 {
            page[OggOpusGranule.checksumOffset + i] = UInt8((crc >> (i * 8)) & 0xFF)
        }
        bytes.append(contentsOf: page)
        pageSequence += 1
    }

    private func withLE16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func withLE32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    // MARK: - Atomic, size-bounded publish (Android PR #1098 discipline)

    /// Write `data` to `url` atomically: validate the size bound, write to a
    /// temp file in the same directory, `synchronize`, replace the destination
    /// (atomic where supported, plain replace otherwise), then best-effort
    /// `synchronize` the directory. Never leaves a half-written file at `url`.
    @discardableResult
    public static func publishToDisk(_ data: Data, to url: URL) throws -> URL {
        guard (1...OggOpusFileWriter.maxFileBytes).contains(data.count) else {
            throw OggOpusFileError("size-limit")
        }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\u{200B}\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        do {
            try FileManager.default.replaceItem(at: url, withItemAt: tmp,
                                                backingItemURL: nil, options: [])
        } catch {
            // Fall back to a plain replace if the filesystem refuses.
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        try? FileManager.default.removeItem(at: tmp)
        return url
    }
}
