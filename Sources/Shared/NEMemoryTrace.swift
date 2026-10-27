//
//  NEMemoryTrace.swift
//  Columba Shared
//
//  Self-reported memory trajectory for the Network Extension, written to a
//  fixed-size ring in the App-Group container so the host app can chart it.
//
//  ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
//  The NE is a separate sandboxed process. The app CANNOT read another
//  process's memory (`proc_pid_rusage` on a foreign pid is EPERM under the
//  sandbox, and libproc.h is not even shipped in the iOS SDK), and iOS exposes
//  no programmatic jetsam report. So the only way to know what the NE was using
//  when iOS killed it is for the NE to write the number down while it is still
//  alive. A SIGKILL does NOT lose buffered file writes — only power loss does —
//  so the last record the dead process wrote is readable by the next launch.
//
//  ── METRIC ──────────────────────────────────────────────────────────────────
//  `task_vm_info.phys_footprint` is the ONLY number comparable to the kernel's
//  kill ceiling (`memorystatus: … exceeded mem limit: ActiveHard <N> MB`).
//  `resident_size` / `ru_maxrss` also count shared file-backed pages and are
//  always higher — comparing them to that ceiling is a category error.
//  `os_proc_available_memory()` is deliberately NOT used: it is
//  `API_UNAVAILABLE(macos)` and returns 0 for any process that "isn't an app",
//  which an app extension may well be. `task_vm_info.limit_bytes_remaining` is
//  the same quantity, is available on every platform this app builds for, and is
//  recorded as 0 = unknown.
//
//  ── SAMPLER THREAD ──────────────────────────────────────────────────────────
//  A detached native `Thread`, NOT an async `Task` or a run-loop `Timer`: the
//  NE's main dispatch thread is blocked during startup / announce floods, so a
//  cooperative sampler silently never ticks and reports a healthy-looking empty
//  trace. A sampler that never ran reads exactly like a process that never grew.
//
//  ── I/O BUDGET ──────────────────────────────────────────────────────────────
//  Writes are batched on purpose. A per-sample synchronous persist previously
//  ACCELERATED the very kill it was measuring (an ~8 s kill cycle fell to ~1 s).
//  So: sample 1 Hz, rewrite the 64-byte live slot at most every 5 s (or on a
//  >= 1 MB jump), and append a ring bucket every 60 s (or on a >= 1 MB jump).
//  The ring is fixed-size and never rotates: bounded disk, bounded memory, and
//  the pre-kill value survives because the jump trigger fires during a ramp.
//
//  This file imports ONLY Foundation and is compiled into BOTH the ColumbaApp
//  and ColumbaNetworkExtension targets (like `ExtensionDiagLog` / `AppGroupPaths`).
//  It MUST stay free of ReticulumSwift / RNSAPI / LXMFSwift so it compiles in the
//  NE target, which links none of those.
//
//  NO-PII CONTRACT: records carry byte counts, timestamps and a pid only.
//

import Foundation

/// Fixed-layout memory trajectory: a header, one live record rewritten in place,
/// and a ring of bucket records. Written by the NE, read by the app.
public enum NEMemoryTrace {

    // MARK: - Layout constants

    /// File magic — a mismatch means "written by an incompatible build", so the
    /// reader returns empty instead of misreading stale bytes.
    static let magic: UInt64 = 0x544D4243 // "CBMT"
    static let layoutVersion: UInt64 = 2

    /// Byte size of one record / of the header. Fixed, so slot N always lives at
    /// the same offset and a killed writer can never shift the addressing.
    /// v2 grew the record by 8 B for `diskWritten` (see the field doc); an
    /// on-disk v1 file has a different size and is dropped on first open (see
    /// `ensureFile`) — it is diagnostic data, not state worth migrating.
    static let recordSize = 72
    static let headerSize = 64

    /// Ring capacity in records. 8192 × 72 B ≈ 576 KB sparse file; at the 1/min
    /// idle flush cadence that is ~5.6 days of history.
    static let defaultRingCapacity = 8192

    #if DEBUG
    /// Test seam: shrink the ring so wrap-around is exercisable without writing
    /// thousands of records. Must be set BEFORE the file is created, since the
    /// capacity is stamped into the header.
    static var ringCapacityOverride: Int?
    #endif

    static var ringCapacity: Int {
        #if DEBUG
        if let override = ringCapacityOverride { return override }
        #endif
        return defaultRingCapacity
    }

    /// Record field offsets (little-endian).
    static let offKind = 0            // u8   (0 = empty slot)
    static let offReason = 4          // u32
    static let offWallMs = 8          // i64
    static let offUptimeMs = 16       // i64
    static let offFootprint = 24      // u64
    static let offWindowMax = 32      // u64
    static let offLifetimePeak = 40   // u64
    static let offLimitRemaining = 48 // u64
    static let offDiskWritten = 56    // u64 (cumulative bytes written to disk)
    /// Sentinel for `diskWritten`: the rusage probe failed, so no disk data
    /// exists for this record. Never a real counter value — 4 EiB of writes.
    static let diskWrittenUnavailable = UInt64.max
    static let offPid = 64            // u32
    static let offChecksum = 68       // u32 (FNV-1a over bytes 0..<68)

    /// Header field offsets.
    static let offMagic = 0           // u32
    static let offVersion = 4         // u16
    static let offRecordSize = 6      // u16
    static let offCapacity = 8        // u32
    static let offWriteIndex = 12     // u32
    static let offRecordCount = 16    // u32
    static let offBootCount = 20      // u32

    /// Offset of the live slot (rewritten in place) and of the ring.
    static let liveSlotOffset = UInt64(headerSize)
    static let ringStartOffset = UInt64(headerSize + recordSize)

    // MARK: - Sampling cadence

    /// Sampler period. 1 Hz is one Mach call per second — negligible next to the
    /// NE's own work, and fine-grained enough to see a reassembly ramp.
    static let sampleIntervalSeconds: Double = 1.0
    /// Rewrite the live slot at most this often (seconds), or on a jump.
    static let liveWriteIntervalSeconds: Double = 5.0
    /// Append a ring bucket at most this often (seconds), or on a jump.
    static let bucketFlushIntervalSeconds: Double = 60.0
    /// A footprint rise of this size forces an immediate live write + bucket
    /// flush, so a kill during a ramp leaves a fresh record behind.
    static let jumpTriggerBytes: UInt64 = 1_048_576

    // MARK: - Record kinds

    public enum Kind: UInt8, Sendable {
        /// Ring slot: a bucket covering the window since the previous bucket.
        case bucket = 1
        /// Ring slot: `startTunnel` — a process generation begins.
        case boot = 2
        /// Ring slot: `stopTunnel` — a CLEAN teardown; `reason` carries the
        /// `NEProviderStopReason` raw value. The ABSENCE of this record at the
        /// end of a generation is what identifies a kill.
        case stop = 3
        /// The live slot: the newest sample, rewritten in place.
        case live = 4
    }

    // MARK: - Types

    /// One decoded record. Field meaning depends on `kind`; see the ring writer.
    public struct Record: Equatable, Sendable {
        public let kind: Kind
        /// `NEProviderStopReason` raw value for `.stop`, else 0.
        public let reason: UInt32
        /// Wall clock — for display.
        public let wallMs: Int64
        /// `CLOCK_UPTIME_RAW` ms — does NOT advance while the device sleeps, so a
        /// wall-clock gap with no uptime gap means the device was asleep and the
        /// chart must draw a gap, not a flat line.
        public let uptimeMs: Int64
        /// `.bucket`: last sample in the window. `.live`: newest sample.
        /// `.boot`/`.stop`: footprint at that instant.
        public let footprint: UInt64
        /// Max footprint observed since the previous bucket was written.
        public let windowMax: UInt64
        /// `ledger_phys_footprint_peak` — never misses a spike between samples.
        public let lifetimePeak: UInt64
        /// `limit_bytes_remaining`; 0 means unknown (see file header).
        public let limitRemaining: UInt64
        /// Cumulative bytes this process has written to disk at record time
        /// (`proc_pid_rusage` → `ri_diskio_byteswritten`). Monotonic within a
        /// generation; resets to ~0 at each process start, so per-generation
        /// totals are `last − first` and per-interval rates are the delta
        /// between consecutive records. This is the volume the OS disk-writes
        /// resource limit measures (the `.ips` reports), whose breach gets the
        /// NE throttled or killed.
        public let diskWritten: UInt64
        /// Process generation. A pid change with no `.stop` record between is the
        /// kill tell, and it survives even a kill before the boot marker landed.
        public let pid: UInt32

        public init(
            kind: Kind, reason: UInt32, wallMs: Int64, uptimeMs: Int64,
            footprint: UInt64, windowMax: UInt64, lifetimePeak: UInt64,
            limitRemaining: UInt64, diskWritten: UInt64 = 0, pid: UInt32
        ) {
            self.kind = kind
            self.reason = reason
            self.wallMs = wallMs
            self.uptimeMs = uptimeMs
            self.footprint = footprint
            self.windowMax = windowMax
            self.lifetimePeak = lifetimePeak
            self.limitRemaining = limitRemaining
            self.diskWritten = diskWritten
            self.pid = pid
        }
    }

    /// Everything readable out of the trace file.
    public struct Trace: Sendable {
        /// Ring records in chronological order, oldest first.
        public var records: [Record] = []
        /// The live slot, if present. Deliberately NOT merged into `records`: the
        /// caller decides whether it is newer than the last bucket of the newest
        /// generation (it is not, after a clean stop).
        public var live: Record?

        public init() {}
    }

    /// Writer state, so the reader can order the ring.
    struct Header: Equatable, Sendable {
        var writeIndex: UInt32 = 0
        var recordCount: UInt32 = 0
        var bootCount: UInt32 = 0
    }

    // MARK: - File location

    /// App-Group file both processes reach. `nil` when the group is unavailable
    /// (e.g. a test runner without the App-Group entitlement).
    public static var fileURL: URL? {
        #if DEBUG
        if let override = fileURLOverride { return override }
        #endif
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        // Under `Library/`, not the container root: `devicectl device copy from`
        // only exposes Library / Documents / tmp inside a container, so a file at
        // the App-Group root cannot be pulled off a device - and pulling it off the
        // device is the whole point of keeping it. Verified on iPhone 14 / iOS
        // 27.0.1, where the root path fails with remoteservices error 11007.
        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("ne-memory.bin")
    }

    #if DEBUG
    /// Test seam: point the trace at a throwaway file.
    static var fileURLOverride: URL?
    #endif

    // MARK: - Sampler state

    private static let lock = NSLock()
    private static var samplerRunning = false
    /// Bumped on every `start()`. A thread only keeps running while its OWN
    /// generation is current: without this, a `stopTunnel` immediately followed
    /// by a `startTunnel` (a tunnel reconnect inside one process) would flip the
    /// shared flag back to true before the old thread checked it, so the old
    /// thread would never exit and the ring would gain a second permanent writer
    /// — double-counted records and doubled I/O for the rest of the process life.
    private static var samplerGeneration = 0

    /// Start the sampler. Idempotent: a tunnel restart inside the same process
    /// must not spawn a second writer into the same ring.
    ///
    /// Runs on a DETACHED NATIVE THREAD — see the file header for why a `Task`
    /// or `Timer` is the wrong tool in the NE.
    public static func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !samplerRunning else { return }
        samplerRunning = true
        samplerGeneration += 1
        let generation = samplerGeneration

        // Record the generation BEFORE the first sample so a kill during startup
        // still leaves a boot marker for the next launch to attribute against.
        // But first preserve the PREVIOUS generation's freshest reading: the
        // live slot is written every 5 s while the ring only every 60 s, and
        // once a new pid boots the reader ignores a live record whose pid no
        // longer matches the newest generation. Without this, a kill+relaunch
        // loses up to 60 s of the dead process's final memory when the new
        // sampler overwrites the slot below.
        flushForeignLiveLocked()
        appendMarkerLocked(kind: .boot, reason: 0)

        let thread = Thread { runSamplerLoop(generation: generation) }
        thread.name = "columba.memory-trace"
        // Background QoS: never compete with delivery work, and still run when
        // the main dispatch thread is wedged.
        thread.qualityOfService = .background
        thread.stackSize = 64 * 1024
        thread.start()
    }

    /// Ask the sampler to stop; it exits within one sample period. The caller
    /// writes the clean-stop marker via `recordStop(reason:)`.
    public static func stopSampling() {
        lock.lock()
        samplerRunning = false
        lock.unlock()
    }

    /// Append a `.stop` marker carrying the `NEProviderStopReason` raw value.
    /// Its presence is the ONLY way the app can tell a clean teardown from a
    /// jetsam kill: there is no `NEProviderStopReason.memoryLow`, and a memory
    /// kill delivers no callback at all.
    public static func recordStop(reason: Int) {
        stopSampling()
        lock.lock()
        defer { lock.unlock() }
        appendMarkerLocked(kind: .stop, reason: UInt32(truncatingIfNeeded: reason))
    }

    // MARK: - Sampler loop

    private static func runSamplerLoop(generation: Int) {
        var header = readHeader()
        var windowMax: UInt64 = 0
        var lastLiveUptimeMs: Int64 = 0
        var lastFlushUptimeMs = Clocks.now().uptimeMs
        var lastFlushedFootprint: UInt64 = MemoryFootprint.sample().footprint

        while isRunning(generation: generation) {
            Thread.sleep(forTimeInterval: sampleIntervalSeconds)
            guard isRunning(generation: generation) else { return }

            let snap = MemoryFootprint.sample()
            // Probe failure → sentinel, never 0: a zero between real readings
            // would fake a counter reset and inflate the next interval's rate.
            let diskWritten = DiskIO.sample()?.writtenBytes ?? diskWrittenUnavailable
            let now = Clocks.now()
            let pid = UInt32(getpid())
            // A jump is measured against what the last bucket recorded, so a
            // sustained climb keeps flushing instead of tripping once.
            let jumped = snap.footprint >= lastFlushedFootprint &+ jumpTriggerBytes
            windowMax = max(windowMax, snap.footprint)

            lock.lock()
            guard samplerRunning, samplerGeneration == generation else { lock.unlock(); return }

            if shouldWriteLive(sinceLiveMs: now.uptimeMs &- lastLiveUptimeMs, jumped: jumped) {
                writeLive(Record(
                    kind: .live, reason: 0,
                    wallMs: now.wallMs, uptimeMs: now.uptimeMs,
                    footprint: snap.footprint, windowMax: windowMax,
                    lifetimePeak: snap.lifetimePeak,
                    limitRemaining: snap.limitRemaining,
                    diskWritten: diskWritten,
                    pid: pid
                ))
                lastLiveUptimeMs = now.uptimeMs
            }

            if shouldFlushBucket(sinceFlushMs: now.uptimeMs &- lastFlushUptimeMs, jumped: jumped) {
                append(Record(
                    kind: .bucket, reason: 0,
                    wallMs: now.wallMs, uptimeMs: now.uptimeMs,
                    footprint: snap.footprint, windowMax: windowMax,
                    lifetimePeak: snap.lifetimePeak,
                    limitRemaining: snap.limitRemaining,
                    diskWritten: diskWritten,
                    pid: pid
                ), header: &header)
                writeHeader(header)
                lastFlushUptimeMs = now.uptimeMs
                lastFlushedFootprint = snap.footprint
                windowMax = 0
            }
            lock.unlock()
        }
    }

    // MARK: - Flush policy (pure — unit-tested)

    /// The live slot is the record that answers "what was it using when it got
    /// killed", so a jump always rewrites it regardless of the interval.
    static func shouldWriteLive(sinceLiveMs: Int64, jumped: Bool) -> Bool {
        jumped || sinceLiveMs >= Int64(liveWriteIntervalSeconds * 1000)
    }

    static func shouldFlushBucket(sinceFlushMs: Int64, jumped: Bool) -> Bool {
        jumped || sinceFlushMs >= Int64(bucketFlushIntervalSeconds * 1000)
    }

    // MARK: - Markers

    /// Locked accessor for the loop condition. `NSLock` is not recursive, so the
    /// thread never reads `samplerRunning` bare.
    private static func isRunning(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return samplerRunning && samplerGeneration == generation
    }

    /// Preserve a dead generation's last known state before a new boot. The
    /// live slot is the freshest record (written every 5 s; ring buckets flush
    /// every 60 s) and the reader only merges it while its pid matches the
    /// newest generation, so a relaunched process must copy its predecessor's
    /// live record into the ring or that reading is lost when the slot is
    /// overwritten. Same-pid live slots (in-process tunnel restart) keep
    /// merging, so only foreign pids are flushed. Skipped when the ring's last
    /// record is already at least as new: the generation stopped cleanly (its
    /// `.stop` marker postdates the last live write, and appending the live
    /// record after the marker would read as a kill), or a previous boot
    /// already flushed this record. Caller must hold `lock`.
    private static func flushForeignLiveLocked() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              data.count >= Int(liveSlotOffset) + recordSize,
              let live = decodeRecord(slice(data, Int(liveSlotOffset), recordSize)),
              live.pid != UInt32(getpid()),
              lastRingRecordLocked(data).map({ live.wallMs > $0.wallMs }) ?? true else { return }
        var header = readHeader()
        append(live, header: &header)
        writeHeader(header)
    }

    /// The newest decodable ring record, or nil when the ring is empty or its
    /// tail is torn (a kill during the write — treat as unknown, flush).
    private static func lastRingRecordLocked(_ data: Data) -> Record? {
        guard let header = decodeHeader(data) else { return nil }
        let filled = min(Int(header.recordCount), ringCapacity)
        guard filled > 0 else { return nil }
        let start = header.recordCount >= UInt32(ringCapacity) ? Int(header.writeIndex) : 0
        let slot = (start + filled - 1) % ringCapacity
        return decodeRecord(slice(data, Int(ringStartOffset) + slot * recordSize, recordSize))
    }

    private static func appendMarkerLocked(kind: Kind, reason: UInt32) {
        let snap = MemoryFootprint.sample()
        let diskWritten = DiskIO.sample()?.writtenBytes ?? diskWrittenUnavailable
        let now = Clocks.now()
        var header = readHeader()
        if kind == .boot { header.bootCount &+= 1 }
        append(Record(
            kind: kind, reason: reason,
            wallMs: now.wallMs, uptimeMs: now.uptimeMs,
            footprint: snap.footprint, windowMax: snap.lifetimePeak,
            lifetimePeak: snap.lifetimePeak,
            limitRemaining: snap.limitRemaining,
            diskWritten: diskWritten,
            pid: UInt32(getpid())
        ), header: &header)
        writeHeader(header)
    }

    // MARK: - Reading (app side)

    /// Read the trace. Returns an empty `Trace` when the file is missing, carries
    /// a foreign magic/version, or is shorter than the header — never a partial
    /// misread. Empty slots and a torn trailing record are skipped.
    public static func readAll() -> Trace {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let header = decodeHeader(data) else { return Trace() }

        var trace = Trace()
        let filled = min(Int(header.recordCount), ringCapacity)
        // Once wrapped, `writeIndex` points at the OLDEST slot; before that the
        // ring starts at 0.
        let start = header.recordCount >= UInt32(ringCapacity) ? Int(header.writeIndex) : 0
        for step in 0..<filled {
            let slot = (start + step) % ringCapacity
            let at = Int(ringStartOffset) + slot * recordSize
            guard let record = decodeRecord(slice(data, at, recordSize)) else { continue }
            trace.records.append(record)
        }

        let liveAt = Int(liveSlotOffset)
        trace.live = decodeRecord(slice(data, liveAt, recordSize))
        return trace
    }

    /// Wipe the ring + live slot. INTERNAL, not a UI affordance: the sampler
    /// caches its header between flushes, so clearing the file out from under a
    /// live writer would leave that writer's slot index stale. Tests only.
    static func clear() {
        guard let url = fileURL else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        _ = ensureFile(url)
    }

    /// Append records through the same slot/header path the sampler uses, without
    /// starting a thread — the deterministic write seam for tests. Production
    /// writes come from `runSamplerLoop` and the boot/stop markers.
    static func appendRecords(_ records: [Record]) {
        lock.lock()
        defer { lock.unlock() }
        var header = readHeader()
        for record in records { append(record, header: &header) }
        writeHeader(header)
    }

    /// Overwrite the live slot without a sampler. Test seam.
    static func writeLiveRecord(_ record: Record) {
        lock.lock()
        defer { lock.unlock() }
        writeLive(record)
    }

    // MARK: - Encoding

    static func encodeHeader(_ header: Header) -> Data {
        var out = Data(count: headerSize)
        out.writeLE(magic, at: offMagic, width: 4)
        out.writeLE(layoutVersion, at: offVersion, width: 2)
        out.writeLE(UInt64(recordSize), at: offRecordSize, width: 2)
        out.writeLE(UInt64(ringCapacity), at: offCapacity, width: 4)
        out.writeLE(UInt64(header.writeIndex), at: offWriteIndex, width: 4)
        out.writeLE(UInt64(header.recordCount), at: offRecordCount, width: 4)
        out.writeLE(UInt64(header.bootCount), at: offBootCount, width: 4)
        return out
    }

    static func decodeHeader(_ data: Data) -> Header? {
        // Every field is sanity-checked, not just trusted: the header is rewritten
        // after each flush, so a write torn by a kill can leave a valid magic with
        // a garbage slot index — which would make the reader plot unrelated bytes
        // as samples.
        guard data.count >= headerSize,
              readLE(data, offMagic, 4) == magic,
              readLE(data, offVersion, 2) == layoutVersion,
              readLE(data, offRecordSize, 2) == recordSize,
              readLE(data, offCapacity, 4) == UInt64(ringCapacity) else { return nil }
        let writeIndex = UInt32(truncatingIfNeeded: readLE(data, offWriteIndex, 4))
        guard writeIndex < UInt32(ringCapacity) else { return nil }
        return Header(
            writeIndex: writeIndex,
            recordCount: UInt32(truncatingIfNeeded: readLE(data, offRecordCount, 4)),
            bootCount: UInt32(truncatingIfNeeded: readLE(data, offBootCount, 4))
        )
    }

    static func encodeRecord(_ record: Record) -> Data {
        var out = Data(count: recordSize)
        out.writeLE(UInt64(record.kind.rawValue), at: offKind, width: 1)
        out.writeLE(UInt64(record.reason), at: offReason, width: 4)
        out.writeLE(UInt64(bitPattern: record.wallMs), at: offWallMs, width: 8)
        out.writeLE(UInt64(bitPattern: record.uptimeMs), at: offUptimeMs, width: 8)
        out.writeLE(record.footprint, at: offFootprint, width: 8)
        out.writeLE(record.windowMax, at: offWindowMax, width: 8)
        out.writeLE(record.lifetimePeak, at: offLifetimePeak, width: 8)
        out.writeLE(record.limitRemaining, at: offLimitRemaining, width: 8)
        out.writeLE(record.diskWritten, at: offDiskWritten, width: 8)
        out.writeLE(UInt64(record.pid), at: offPid, width: 4)
        out.writeLE(UInt64(checksum(of: out)), at: offChecksum, width: 4)
        return out
    }

    /// FNV-1a over the record body, so a slot whose write was torn by a kill is
    /// REJECTED instead of decoded as a real (and badly wrong) sample. Pure
    /// integer math on purpose: no CryptoKit, keeps this file Foundation-only and
    /// byte-identical across platforms.
    static func checksum(of data: Data) -> UInt32 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data.prefix(offChecksum) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return UInt32(truncatingIfNeeded: hash >> 32)
    }

    /// `nil` for an empty slot, an unknown kind, a short buffer, or a checksum
    /// mismatch — the last two being exactly what a write torn by a kill looks
    /// like. Skipping is always right: a half-written record would otherwise be
    /// reported as the memory figure of a process that never used it.
    static func decodeRecord(_ data: Data?) -> Record? {
        guard let data, data.count == recordSize else { return nil }
        guard UInt32(truncatingIfNeeded: readLE(data, offChecksum, 4)) == checksum(of: data)
        else { return nil }
        guard let kind = Kind(rawValue: UInt8(truncatingIfNeeded: readLE(data, offKind, 1))) else {
            return nil
        }
        return Record(
            kind: kind,
            reason: UInt32(truncatingIfNeeded: readLE(data, offReason, 4)),
            wallMs: Int64(bitPattern: readLE(data, offWallMs, 8)),
            uptimeMs: Int64(bitPattern: readLE(data, offUptimeMs, 8)),
            footprint: readLE(data, offFootprint, 8),
            windowMax: readLE(data, offWindowMax, 8),
            lifetimePeak: readLE(data, offLifetimePeak, 8),
            limitRemaining: readLE(data, offLimitRemaining, 8),
            diskWritten: readLE(data, offDiskWritten, 8),
            pid: UInt32(truncatingIfNeeded: readLE(data, offPid, 4))
        )
    }

    // MARK: - File primitives

    /// Create the trace file with the protection class the NE needs to keep
    /// writing while the device is locked-after-first-unlock, mirroring
    /// `ExtensionDiagLog`. A default-protection file silently stops recording
    /// exactly during the deliver-while-locked window.
    private static func ensureFile(_ url: URL) -> Bool {
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        if FileManager.default.fileExists(atPath: url.path) {
            // Reject a file whose size does not match THIS build's layout (a v1
            // ring from an older build, or a torn creation): slot addressing
            // differs, so writing would interleave two layouts. The trace is
            // diagnostics, not state — drop and recreate rather than migrate.
            let expectedSize = Int(headerSize) + recordSize * (1 + ringCapacity)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
                .flatMap { $0[.size] as? Int } ?? 0
            if size != expectedSize {
                try? FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: url.path) {
                // Re-assert on every open: a file created by another process (or
                // an older build) may carry default protection, which blocks
                // writes on a locked device. Cheap and idempotent.
                try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
                return true
            }
        }
        // Header + live slot + a zero-filled ring. The zero fill is what makes a
        // never-written slot distinguishable from a corrupt one, and it is written
        // once, at boot, not per sample.
        // The App-Group `Library/` directory is not guaranteed to exist.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var initial = encodeHeader(Header())
        initial.append(Data(count: recordSize))
        initial.append(Data(count: ringCapacity * recordSize))
        return FileManager.default.createFile(atPath: url.path, contents: initial, attributes: attributes)
    }

    /// Append one record into the next ring slot and advance the write index.
    /// Caller holds `lock`.
    private static func append(_ record: Record, header: inout Header) {
        guard let url = fileURL, ensureFile(url) else { return }
        let slot = Int(header.writeIndex) % ringCapacity
        let offset = ringStartOffset + UInt64(slot) * UInt64(recordSize)
        write(data: encodeRecord(record), to: url, at: offset)
        header.writeIndex = UInt32((slot + 1) % ringCapacity)
        header.recordCount &+= 1
    }

    /// Rewrite the live slot in place. Caller holds `lock`.
    private static func writeLive(_ record: Record) {
        guard let url = fileURL, ensureFile(url) else { return }
        write(data: encodeRecord(record), to: url, at: liveSlotOffset)
    }

    /// Rewrite the header. Caller holds `lock`.
    private static func writeHeader(_ header: Header) {
        guard let url = fileURL, ensureFile(url) else { return }
        write(data: encodeHeader(header), to: url, at: 0)
    }

    private static func readHeader() -> Header {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let header = decodeHeader(data) else { return Header() }
        return header
    }

    /// In-place positional write. No `fsync`: a jetsam SIGKILL does not lose
    /// buffered writes (only power loss does), and forcing the sync would add
    /// precisely the I/O load observed to accelerate the kill.
    private static func write(data: Data, to url: URL, at offset: UInt64) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            handle.write(data)
        } catch {
            // Best-effort side channel: a failed write must never destabilize the
            // NE, and there is no safer place to swallow it than here.
        }
    }

    // MARK: - Byte helpers

    private static func slice(_ data: Data, _ offset: Int, _ count: Int) -> Data? {
        guard offset >= 0, count > 0, offset + count <= data.count else { return nil }
        let lower = data.startIndex + offset
        return data.subdata(in: lower..<(lower + count))
    }

    private static func readLE(_ data: Data, _ offset: Int, _ width: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<width {
            value |= UInt64(data[data.startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}

private extension Data {
    /// Write `value` as `width` little-endian bytes at `offset`.
    mutating func writeLE(_ value: UInt64, at offset: Int, width: Int) {
        for i in 0..<width {
            self[startIndex + offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i))
        }
    }
}

// MARK: - Mach sampling

/// `task_info(TASK_VM_INFO)` reader — the only source of the jetsam-comparable
/// footprint. Foundation re-exports Darwin, so this stays Foundation-only.
enum MemoryFootprint {

    struct Snapshot: Equatable, Sendable {
        /// The kill metric.
        var footprint: UInt64 = 0
        /// Peak footprint since process launch — catches spikes between samples.
        var lifetimePeak: UInt64 = 0
        /// Headroom to the current limit; 0 = unknown (see `NEMemoryTrace` header).
        var limitRemaining: UInt64 = 0
    }

    static func sample() -> Snapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return Snapshot() }
        return Snapshot(
            footprint: UInt64(info.phys_footprint),
            // bitPattern: the ledger value is an int64 and a trap on a negative
            // read would take the sampler down inside the NE.
            lifetimePeak: UInt64(bitPattern: info.ledger_phys_footprint_peak),
            limitRemaining: UInt64(info.limit_bytes_remaining)
        )
    }
}

// MARK: - Disk I/O sampling

/// Cumulative disk-write counter for THIS process, from
/// `proc_pid_rusage(RUSAGE_INFO_V6)`. `ri_diskio_byteswritten` counts physical
/// writes after page-cache writeback — the closest public probe to the
/// "file backed memory dirtied" volume the OS disk-writes resource limit
/// measures (the `*.diskwrites_resource` `.ips` reports).
///
/// `proc_pid_rusage` is NOT declared in the iOS SDK's headers (libproc.h ships
/// only on macOS), but the symbol has been in libsystem since iOS 8 and is
/// callable for the current process without entitlement — resolve it once via
/// `dlsym(RTLD_DEFAULT, …)`. Reading your own rusage needs no privilege.
enum DiskIO {

    struct Snapshot: Equatable, Sendable {
        /// Physical bytes written since process start.
        var writtenBytes: UInt64 = 0
        /// Logical writes (the dirtying-side counter, same source).
        var logicalWrites: UInt64 = 0
    }

    private typealias ProcPidRusageFn = @convention(c) (Int32, Int32, UnsafeMutableRawPointer) -> Int32

    private static let procPidRusage: ProcPidRusageFn? = {
        // Darwin's RTLD_DEFAULT is (void*)-2, NOT NULL — a glibc-ism cost a
        // device cycle here: dlsym(NULL, …) fails outright on iOS. -2 is never
        // 0, so the failable bitPattern init cannot trip.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2)!, "proc_pid_rusage") else {
            return nil
        }
        return unsafeBitCast(sym, to: ProcPidRusageFn.self)
    }()

    /// nil = the probe failed (symbol missing or syscall error). The caller must
    /// NOT store 0 for this: 0 is a legitimate counter reading, and a zero
    /// between real readings would fake a counter reset and inflate the next
    /// interval's rate. The sampler stores the `diskWrittenUnavailable`
    /// sentinel instead, which the analyzer renders as "no data".
    static func sample() -> Snapshot? {
        guard let fn = procPidRusage else {
            logFailureOnce("proc_pid_rusage symbol not found")
            return nil
        }
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            fn(getpid(), RUSAGE_INFO_V6, UnsafeMutableRawPointer(pointer))
        }
        guard result == 0 else {
            logFailureOnce("proc_pid_rusage returned \(result), errno \(errno)")
            return nil
        }
        return Snapshot(writtenBytes: info.ri_diskio_byteswritten, logicalWrites: info.ri_logical_writes)
    }

    /// The failure is persistent-or-never for a given process, so one line is
    /// all the diagnosis the rolling log needs.
    private static func logFailureOnce(_ detail: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        ExtensionDiagLog.log("MEMTRACE disk probe unavailable: \(detail)")
    }

    private static var loggedFailure = false
}

/// Wall clock + monotonic uptime. The pair is what lets the chart tell a device
/// nap from a memory plateau.
enum Clocks {

    struct Now: Equatable, Sendable {
        var wallMs: Int64
        var uptimeMs: Int64
    }

    static func now() -> Now {
        var time = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &time)
        return Now(
            wallMs: Int64(Date().timeIntervalSince1970 * 1000),
            uptimeMs: Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
        )
    }
}
