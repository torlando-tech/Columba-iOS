import XCTest
@testable import ColumbaApp

/// Regression coverage for the Network Extension's self-reported memory trace.
///
/// Two properties carry real weight here and would silently corrupt the chart if
/// they regressed:
///
/// 1. A record whose write was torn by a kill must be REJECTED, never decoded.
///    A half-written slot decodes as a plausible-looking sample with the wrong
///    byte counts, and the app would report that as the memory of a process that
///    never used it.
/// 2. A kill is identified by the ABSENCE of a clean-stop marker. iOS delivers no
///    memory-kill callback, and `NEProviderStopReason` has no memory case, so
///    this absence is the only available evidence — the attribution logic must
///    not invent a kill for a clean teardown, and must not miss one either.
final class NEMemoryTraceTests: XCTestCase {

    private var fileURL: URL!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ne-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("ne-memory.bin")
        NEMemoryTrace.ringCapacityOverride = nil
        NEMemoryTrace.fileURLOverride = fileURL
    }

    override func tearDown() {
        NEMemoryTrace.fileURLOverride = nil
        NEMemoryTrace.ringCapacityOverride = nil
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    // MARK: - Helpers

    private func wall(_ seconds: TimeInterval) -> Int64 {
        Int64(base.addingTimeInterval(seconds).timeIntervalSince1970 * 1000)
    }

    private func megabytes(_ value: UInt64) -> UInt64 { value * 1_048_576 }

    private func makeRecord(
        _ kind: NEMemoryTrace.Kind,
        pid: UInt32,
        at seconds: TimeInterval,
        footprint: UInt64 = 0,
        windowMax: UInt64 = 0,
        lifetimePeak: UInt64 = 0,
        limit: UInt64 = 0,
        reason: UInt32 = 0
    ) -> NEMemoryTrace.Record {
        NEMemoryTrace.Record(
            kind: kind, reason: reason,
            wallMs: wall(seconds), uptimeMs: Int64(seconds * 1000),
            footprint: footprint, windowMax: windowMax,
            lifetimePeak: lifetimePeak, limitRemaining: limit, pid: pid
        )
    }

    // MARK: - Byte layout

    func testRecordRoundTripPreservesEveryField() {
        let original = NEMemoryTrace.Record(
            kind: .stop, reason: 12,
            wallMs: wall(7), uptimeMs: -4_294_967_296,
            footprint: megabytes(47), windowMax: 1 << 40,
            lifetimePeak: 1 << 41, limitRemaining: 1 << 42, pid: 42_424_242
        )
        XCTAssertEqual(NEMemoryTrace.decodeRecord(NEMemoryTrace.encodeRecord(original)), original)
    }

    func testTornRecordIsRejectedInsteadOfPlotted() {
        let record = makeRecord(.bucket, pid: 7, at: 3, footprint: megabytes(30), lifetimePeak: megabytes(31))
        var bytes = NEMemoryTrace.encodeRecord(record)
        // A kill mid-`write()` can commit only the leading bytes of a slot. Zeroing
        // the tail is the cheapest faithful stand-in for that.
        for index in 56..<NEMemoryTrace.recordSize { bytes[bytes.startIndex + index] = 0 }
        XCTAssertNil(NEMemoryTrace.decodeRecord(bytes), "a torn slot must never decode as a sample")
    }

    func testEmptySlotIsRejected() {
        XCTAssertNil(NEMemoryTrace.decodeRecord(Data(count: NEMemoryTrace.recordSize)))
    }

    func testShortBufferIsRejected() {
        let record = makeRecord(.bucket, pid: 7, at: 3, footprint: megabytes(30))
        let encoded = NEMemoryTrace.encodeRecord(record)
        XCTAssertNil(NEMemoryTrace.decodeRecord(encoded.prefix(20)))
    }

    // MARK: - Ring behaviour

    func testRingWrapsAndStaysChronological() {
        NEMemoryTrace.ringCapacityOverride = 4
        let written = (1...7).map {
            makeRecord(.bucket, pid: 1, at: TimeInterval($0), footprint: megabytes(UInt64($0)))
        }
        NEMemoryTrace.appendRecords(written)

        let read = NEMemoryTrace.readAll().records
        XCTAssertEqual(read.count, 4, "the ring must stay bounded at its capacity")
        XCTAssertEqual(read.map(\.uptimeMs), [4_000, 5_000, 6_000, 7_000], "oldest first, newest dropped last")
    }

    func testLiveSlotIsReadBackSeparatelyFromTheRing() {
        NEMemoryTrace.appendRecords([makeRecord(.bucket, pid: 1, at: 1, footprint: megabytes(10))])
        NEMemoryTrace.writeLiveRecord(makeRecord(.live, pid: 1, at: 2, footprint: megabytes(11)))

        let trace = NEMemoryTrace.readAll()
        XCTAssertEqual(trace.records.count, 1)
        XCTAssertEqual(trace.live?.footprint, megabytes(11))
    }

    func testForeignOrCorruptFileYieldsNoDataRatherThanGarbage() throws {
        try Data((0..<500).map { _ in UInt8.random(in: 0...255) }).write(to: fileURL)
        let trace = NEMemoryTrace.readAll()
        XCTAssertTrue(trace.records.isEmpty)
        XCTAssertNil(trace.live)
        XCTAssertFalse(NEMemoryHistory.analyze(trace, tunnelConnected: false).hasTrace)
    }

    func testMissingFileYieldsEmptyTrace() {
        XCTAssertTrue(NEMemoryTrace.readAll().records.isEmpty)
    }

    // MARK: - Flush policy

    func testLiveSlotWritesOnIntervalOrJump() {
        XCTAssertFalse(NEMemoryTrace.shouldWriteLive(sinceLiveMs: 4_000, jumped: false))
        XCTAssertTrue(NEMemoryTrace.shouldWriteLive(sinceLiveMs: 5_000, jumped: false))
        // A jump always wins: the live slot is the record that answers "what was
        // it using when it got killed", so it must be fresh during a ramp.
        XCTAssertTrue(NEMemoryTrace.shouldWriteLive(sinceLiveMs: 0, jumped: true))
    }

    func testBucketFlushesOnIntervalOrJump() {
        XCTAssertFalse(NEMemoryTrace.shouldFlushBucket(sinceFlushMs: 59_000, jumped: false))
        XCTAssertTrue(NEMemoryTrace.shouldFlushBucket(sinceFlushMs: 60_000, jumped: false))
        XCTAssertTrue(NEMemoryTrace.shouldFlushBucket(sinceFlushMs: 0, jumped: true))
    }

    // MARK: - Kill attribution

    func testGenerationWithoutStopMarkerIsAttributedAsKill() throws {
        let trace = traceOf([
            makeRecord(.boot, pid: 100, at: 0, footprint: megabytes(8), lifetimePeak: megabytes(8)),
            makeRecord(.bucket, pid: 100, at: 10, footprint: megabytes(20), lifetimePeak: megabytes(20)),
            makeRecord(.bucket, pid: 100, at: 20, footprint: megabytes(45), lifetimePeak: megabytes(49)),
            makeRecord(.boot, pid: 200, at: 30, footprint: megabytes(9), lifetimePeak: megabytes(9)),
            makeRecord(.bucket, pid: 200, at: 40, footprint: megabytes(12), lifetimePeak: megabytes(12)),
        ])
        let summary = NEMemoryHistory.analyze(trace, tunnelConnected: true, now: base.addingTimeInterval(120))

        let kill = try XCTUnwrap(summary.lastKill)
        XCTAssertEqual(kill.kind, .kill)
        XCTAssertEqual(kill.date, base.addingTimeInterval(20), "attributed to the last sample the dead process wrote")
        XCTAssertEqual(kill.lastSeenMB ?? -1, 45.0, accuracy: 0.001)
        XCTAssertEqual(kill.peakMB ?? -1, 49.0, accuracy: 0.001, "peak comes from the lifetime peak, not the last sample")
        XCTAssertEqual(summary.restarts24h, 2)
        XCTAssertEqual(summary.current?.footprintMB ?? -1, 12.0, accuracy: 0.001)
    }

    func testCleanStopIsNeverReportedAsAKill() {
        let trace = traceOf([
            makeRecord(.boot, pid: 100, at: 0, footprint: megabytes(8)),
            makeRecord(.bucket, pid: 100, at: 10, footprint: megabytes(20)),
            makeRecord(.stop, pid: 100, at: 20, footprint: megabytes(21), reason: 1),
        ])
        let summary = NEMemoryHistory.analyze(trace, tunnelConnected: false, now: base.addingTimeInterval(120))

        XCTAssertNil(summary.lastKill, "a generation that wrote its stop marker was torn down cleanly")
        let stop = summary.events.first { event in
            if case .cleanStop = event.kind { return true }
            return false
        }
        XCTAssertEqual(stop?.kind, .cleanStop(reason: 1))
    }

    func testNewestGenerationIsAmbiguousUntilTunnelStateIsKnown() {
        let trace = traceOf([
            makeRecord(.boot, pid: 100, at: 0, footprint: megabytes(8)),
            makeRecord(.bucket, pid: 100, at: 10, footprint: megabytes(20)),
        ])
        let now = base.addingTimeInterval(120)

        // Tunnel up: the missing stop marker just means "still running".
        let running = NEMemoryHistory.analyze(trace, tunnelConnected: true, now: now)
        XCTAssertNil(running.lastKill)
        XCTAssertNotNil(running.current)

        // Tunnel down: the same bytes now mean the process died without stopping.
        let dead = NEMemoryHistory.analyze(trace, tunnelConnected: false, now: now)
        XCTAssertNotNil(dead.lastKill)
        XCTAssertNil(dead.current, "a corpse is not a live reading")
    }

    func testStaleLiveSlotIsNotMergedAfterCleanStop() {
        let stopped = makeRecord(.stop, pid: 5, at: 20, footprint: megabytes(21))
        var trace = traceOf([makeRecord(.bucket, pid: 5, at: 10, footprint: megabytes(20)), stopped])
        trace.live = makeRecord(.live, pid: 5, at: 15, footprint: megabytes(20))
        XCTAssertEqual(NEMemoryHistory.mergedRecords(trace).count, 2, "the live slot predates the stop marker")

        trace.live = makeRecord(.live, pid: 5, at: 25, footprint: megabytes(22))
        XCTAssertEqual(NEMemoryHistory.mergedRecords(trace).count, 3)
    }

    // MARK: - Chart continuity

    func testDeviceSleepGapBreaksTheLine() {
        let trace = traceOf([
            makeRecord(.bucket, pid: 1, at: 0, footprint: megabytes(10)),
            makeRecord(.bucket, pid: 1, at: 60, footprint: megabytes(11)),
            makeRecord(.bucket, pid: 1, at: 900, footprint: megabytes(12)),
        ])
        let points = NEMemoryHistory.analyze(trace, tunnelConnected: true, now: base.addingTimeInterval(1_000)).points

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].segment, points[1].segment, "60 s apart is continuous")
        XCTAssertNotEqual(points[1].segment, points[2].segment, "a 14-minute gap must not be bridged")
    }

    func testGenerationBoundaryBreaksTheLine() {
        let trace = traceOf([
            makeRecord(.bucket, pid: 1, at: 0, footprint: megabytes(10)),
            makeRecord(.bucket, pid: 2, at: 60, footprint: megabytes(11)),
        ])
        let points = NEMemoryHistory.analyze(trace, tunnelConnected: true, now: base.addingTimeInterval(120)).points
        XCTAssertNotEqual(points[0].segment, points[1].segment, "two processes must never be joined by one line")
    }

    // MARK: - End to end through the file

    /// The whole pipeline the Memory Usage screen runs — real writer, real reader,
    /// real analyzer — over three generations where the middle one was killed
    /// mid-ramp. Pins the exact figures the kill card and header print.
    func testMultiGenerationFileProducesTheDisplayedFigures() throws {
        NEMemoryTrace.ringCapacityOverride = 64
        NEMemoryTrace.clear()

        NEMemoryTrace.appendRecords([
            makeRecord(.boot, pid: 100, at: 0),
            makeRecord(.bucket, pid: 100, at: 60, footprint: megabytes(30), windowMax: megabytes(31)),
            makeRecord(.stop, pid: 100, at: 120, reason: 1),
        ])
        NEMemoryTrace.appendRecords([
            makeRecord(.boot, pid: 200, at: 300),
            makeRecord(.bucket, pid: 200, at: 360, footprint: megabytes(41), windowMax: megabytes(42), limit: megabytes(4)),
            makeRecord(.bucket, pid: 200, at: 420, footprint: megabytes(47), windowMax: megabytes(48), lifetimePeak: megabytes(48), limit: megabytes(2)),
        ])
        NEMemoryTrace.appendRecords([makeRecord(.boot, pid: 300, at: 600)])
        NEMemoryTrace.writeLiveRecord(makeRecord(
            .live, pid: 300, at: 660,
            footprint: megabytes(33), windowMax: megabytes(34),
            lifetimePeak: megabytes(34), limit: megabytes(17)
        ))

        let trace = try XCTUnwrap(NEMemoryTrace.readAll())
        XCTAssertEqual(trace.records.count, 7, "the live slot is not part of the ring")
        XCTAssertEqual(trace.live?.pid, 300)

        let summary = NEMemoryHistory.analyze(trace, tunnelConnected: true, now: base.addingTimeInterval(700))

        XCTAssertEqual(summary.lastKill?.kind, .kill)
        XCTAssertEqual(summary.lastKill?.date, base.addingTimeInterval(420))
        XCTAssertEqual(summary.lastKill?.lastSeenMB ?? -1, 47.0, accuracy: 0.001)
        XCTAssertEqual(summary.lastKill?.peakMB ?? -1, 48.0, accuracy: 0.001)
        XCTAssertEqual(summary.lastKill?.headroomMB ?? -1, 2.0, accuracy: 0.001)
        XCTAssertEqual(summary.current?.pid, 300)
        XCTAssertEqual(summary.current?.footprintMB ?? -1, 33.0, accuracy: 0.001)
        XCTAssertEqual(summary.peak24hMB ?? -1, 48.0, accuracy: 0.001)
        XCTAssertEqual(summary.restarts24h, 3)
        XCTAssertEqual(summary.points.count, 5, "samples only: markers must not be plotted")
        XCTAssertEqual(Set(summary.points.map(\.pid)).count, 3)
        XCTAssertEqual(Set(summary.points.map(\.segment)).count, 3, "three processes, three lines")
    }

    // MARK: - Helpers (trace construction)

    /// Build a `Trace` through the real writer so the tests exercise the on-disk
    /// layout, not just the in-memory model.
    private func traceOf(_ records: [NEMemoryTrace.Record]) -> NEMemoryTrace.Trace {
        NEMemoryTrace.clear()
        NEMemoryTrace.appendRecords(records)
        return NEMemoryTrace.readAll()
    }
}
