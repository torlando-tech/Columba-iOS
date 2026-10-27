//
//  NEMemoryHistory.swift
//  ColumbaApp
//
//  Turns the Network Extension's self-reported memory ring (`NEMemoryTrace`,
//  written by the NE process into the App-Group container) into the series and
//  the kill attribution the settings chart renders.
//
//  ── WHY THIS LIVES IN THE APP ───────────────────────────────────────────────
//  The NE cannot read its own future: when iOS jetsams it, the process is
//  SIGKILLed with no callback. Everything knowable about a kill is therefore
//  what the dead process managed to write down, plus what is ABSENT from it.
//  This file is where that absence is interpreted.
//
//  ── HOW A KILL IS DETECTED ──────────────────────────────────────────────────
//  A process generation is a run of records sharing one pid. It ends either with
//  a `.stop` record (the NE saw `stopTunnel`, so the teardown was clean and
//  `reason` says who asked) or with nothing at all. "Nothing at all" is the kill
//  signature: there is no `NEProviderStopReason.memoryLow` to look for, and a
//  memory kill delivers no callback, so absence is the only available evidence.
//  The newest generation is ambiguous — no `.stop` means either "still running"
//  or "killed and not yet restarted" — which is why `tunnelConnected` is an
//  input rather than a guess.
//

import Foundation
import NetworkExtension

/// Analysis of the NE memory trace: chart series, generation boundaries, and the
/// memory figure to report for a process iOS killed.
enum NEMemoryHistory {

    // MARK: - Output types

    /// One plotted sample. `segment` breaks the line wherever continuity is not
    /// honest: across a process generation boundary and across a device sleep.
    struct Point: Identifiable, Equatable {
        let id: Int
        let date: Date
        /// Footprint at the end of the sample window (MB).
        let footprintMB: Double
        /// Highest footprint inside the window (MB) — the spike envelope.
        let windowMaxMB: Double
        /// Cumulative bytes this generation had written to disk at this point
        /// (MB); monotonic within a segment, resets at a process restart.
        let diskWrittenMB: Double
        /// Disk-write rate over the interval since the previous point in the
        /// same segment (KB/s); nil for a segment's first point. Sustained rate
        /// above `dailyDiskWriteBudgetBytes / 86_400` is what gets the NE
        /// killed by the disk-writes resource limit.
        let diskRateKBs: Double?
        let segment: Int
        let pid: UInt32
    }

    enum EventKind: Equatable {
        case boot
        /// Clean teardown; carries the `NEProviderStopReason` raw value.
        case cleanStop(reason: Int)
        /// The generation ended with no `stopTunnel` marker: killed.
        case kill
    }

    struct Event: Identifiable, Equatable {
        let id: Int
        let date: Date
        let kind: EventKind
        /// Last footprint the dead generation wrote (MB), when known.
        let lastSeenMB: Double?
        /// Peak footprint during that generation's lifetime (MB), when known.
        let peakMB: Double?
        /// Headroom to the limit at the last sample (MB); nil when the OS
        /// reported no limit for this process.
        let headroomMB: Double?
        /// Total bytes that generation wrote to disk (MB), when the trace
        /// carries the counter; nil for boot markers and pre-v2 rings.
        let diskWrittenMB: Double?
    }

    /// The newest generation, while it is still up.
    struct Current: Equatable {
        let footprintMB: Double
        let windowMaxMB: Double
        /// Peak since that process launched (MB).
        let peakMB: Double
        /// Headroom to the current limit (MB); nil = unknown.
        let headroomMB: Double?
        let startedAt: Date
        let pid: UInt32
    }

    struct Summary: Equatable {
        /// False when the trace file does not exist yet — i.e. no NE process has
        /// run since the feature shipped, which is NOT the same as "0 MB".
        let hasTrace: Bool
        let points: [Point]
        let events: [Event]
        let current: Current?
        let peak24hMB: Double?
        /// NE process generations started in the last 24 h (a kill shows up here).
        let restarts24h: Int
        let lastKill: Event?

        init(
            hasTrace: Bool = false, points: [Point] = [], events: [Event] = [],
            current: Current? = nil, peak24hMB: Double? = nil,
            restarts24h: Int = 0, lastKill: Event? = nil
        ) {
            self.hasTrace = hasTrace
            self.points = points
            self.events = events
            self.current = current
            self.peak24hMB = peak24hMB
            self.restarts24h = restarts24h
            self.lastKill = lastKill
        }
    }

    // MARK: - Stop reasons

    /// Human-readable name for the `NEProviderStopReason` raw value a `.stop`
    /// marker carries. Uses the real enum rather than duplicating the integers,
    /// so the names cannot drift from the SDK; unknown codes (a newer SDK
    /// writing an older app's file) fall through to a raw-value string.
    /// Values from the iPhoneOS 27.1 SDK `NEProvider.h`.
    static func stopReasonName(_ raw: Int) -> String {
        // `rawValue:` returns an optional; bind it first so `case .none` below
        // matches the ENUM's none case and not Optional.none.
        guard let reason = NEProviderStopReason(rawValue: raw) else {
            return "unknown reason code \(raw)"
        }
        switch reason {
        case .none: return "no specific reason"
        case .userInitiated: return "stopped by the user"
        case .providerFailed: return "provider failed"
        case .noNetworkAvailable: return "no network available"
        case .unrecoverableNetworkChange: return "unrecoverable network change"
        case .providerDisabled: return "provider disabled"
        case .authenticationCanceled: return "authentication cancelled"
        case .configurationFailed: return "configuration failed"
        case .idleTimeout: return "idle timeout"
        case .configurationDisabled: return "configuration disabled"
        case .configurationRemoved: return "configuration removed"
        case .superceded: return "superceded by a higher-priority configuration"
        case .userLogout: return "user logout"
        case .userSwitch: return "user switch"
        case .connectionFailed: return "connection failed"
        case .sleep: return "device went to sleep"
        case .appUpdate: return "provider app updating"
        case .internalError: return "internal error"
        @unknown default: return "unknown reason code \(raw)"
        }
    }

    // MARK: - Thresholds

    /// Wall-clock gap beyond which the series is broken rather than bridged.
    /// Buckets land at worst every 60 s, so a 3-minute gap means the writer was
    /// not running (device asleep, or the process gone).
    static let gapThresholdSeconds: TimeInterval = 180

    /// How far wall time may run ahead of the uptime clock before the line is
    /// broken as a device sleep. Sleep pauses `mach_absolute_time` (the source
    /// of `uptimeMs`) but not `wallMs`, so a 60 s nap between buckets looks like
    /// a 60 s wall gap with ~1 s of uptime — far below `gapThresholdSeconds`,
    /// yet nothing was recorded. Normal operation keeps the two clocks in step
    /// (both advance by the sample interval), so a 30 s skew is decisively
    /// abnormal and cannot be produced by scheduler jitter.
    static let sleepSkewSeconds: TimeInterval = 30

    static let daySeconds: TimeInterval = 86_400

    /// Daily disk-write budget for a background process, as the OS states it in
    /// the `*.diskwrites_resource` `.ips` reports pulled off the iPhone 14
    /// ("limit of 12,137 KB … over 86400 seconds" — ~0.14 KB/s sustained). The
    /// reference line the disk chart draws; a generation whose cumulative
    /// writes cross this gets throttled, then killed.
    static let dailyDiskWriteBudgetBytes: UInt64 = 12_137 * 1024

    // MARK: - Analysis

    /// Whether the tunnel process is believed alive, gone, or mid-transition.
    /// Kill attribution needs a stable verdict: `.connecting`/`.connected` mean
    /// the NE is recording right now (a kill must not be inferred from the
    /// missing stop marker), `.disconnected`/`.invalid` mean it is gone, and
    /// `.disconnecting`/`.reasserting` leave the newest generation undecided —
    /// it is neither a corpse nor a live reading yet.
    enum TunnelState: Equatable {
        case alive, gone, undecided

        init(_ status: NEVPNStatus) {
            switch status {
            case .connected, .connecting: self = .alive
            case .disconnected, .invalid: self = .gone
            case .disconnecting, .reasserting: self = .undecided
            @unknown default: self = .undecided
            }
        }
    }

    /// - Parameter tunnelState: whether the VPN/NE is alive right now. Decides
    ///   the one ambiguous case — a newest generation with no stop marker.
    static func analyze(
        _ trace: NEMemoryTrace.Trace,
        tunnelState: TunnelState,
        now: Date = Date()
    ) -> Summary {
        let merged = mergedRecords(trace)
        guard !merged.isEmpty else { return Summary(hasTrace: trace.live != nil || !trace.records.isEmpty) }

        let generations = groupByGeneration(merged)
        var events: [Event] = []
        var points: [Point] = []
        var segment = 0
        var previousDate: Date?
        var previousUptimeMs: Int64?
        var previousPid: UInt32?
        var eventId = 0
        var pointId = 0

        for (index, generation) in generations.enumerated() {
            let last = generation[generation.count - 1]
            let endedCleanly = last.kind == .stop
            let isLatestGeneration = index == generations.count - 1
            // No stop marker + (a newer generation exists, or the tunnel is
            // believed gone now) ⇒ the process was killed. A newer generation is
            // itself proof: iOS only relaunches the NE after it tore the previous
            // one down. A mid-transition state leaves the newest generation
            // undecided — `.connecting` means it is recording right now, and
            // showing "stopped unexpectedly" for a live process is the exact
            // false kill this state exists to prevent.
            let killed = !endedCleanly && (!isLatestGeneration || tunnelState == .gone)

            if let first = generation.first, first.kind == .boot {
                events.append(Event(
                    id: eventId, date: date(fromMs: first.wallMs), kind: .boot,
                    lastSeenMB: nil, peakMB: nil, headroomMB: nil, diskWrittenMB: nil
                ))
                eventId += 1
            }

            // Per-generation disk total: `last − first` of the cumulative
            // counter. `first.diskWritten == 0` also covers a pre-v2 ring, where
            // no record ever carries the counter.
            let diskTotalMB: Double? = {
                let firstDisk = generation[0].diskWritten
                guard last.diskWritten > firstDisk else { return nil }
                return megabytes(last.diskWritten - firstDisk)
            }()

            if killed {
                // The best number for "what was it using when it got killed":
                // the LAST footprint it wrote (`last` — the maximum would pair a
                // stale high reading with this event's date and headroom) and
                // the peak it reached — the latter from
                // `ledger_phys_footprint_peak`, which catches spikes that fell
                // between samples and so is never under-reported.
                let lastSeen = last.footprint
                let peak = max(
                    generation.map { $0.lifetimePeak }.max() ?? 0,
                    generation.map { $0.windowMax }.max() ?? 0
                )
                events.append(Event(
                    id: eventId, date: date(fromMs: last.wallMs), kind: .kill,
                    lastSeenMB: megabytes(lastSeen),
                    peakMB: peak > 0 ? megabytes(peak) : nil,
                    headroomMB: last.limitRemaining > 0 ? megabytes(last.limitRemaining) : nil,
                    diskWrittenMB: diskTotalMB
                ))
                eventId += 1
            } else if endedCleanly {
                events.append(Event(
                    id: eventId, date: date(fromMs: last.wallMs),
                    kind: .cleanStop(reason: Int(last.reason)),
                    lastSeenMB: megabytes(last.footprint),
                    peakMB: last.lifetimePeak > 0 ? megabytes(last.lifetimePeak) : nil,
                    headroomMB: last.limitRemaining > 0 ? megabytes(last.limitRemaining) : nil,
                    diskWrittenMB: diskTotalMB
                ))
                eventId += 1
            }

            // The disk counter resets at process start, so rate and total are
            // per-generation. `previousPlotted` is the last plotted record in
            // THIS generation: its delta covers exactly the interval between
            // plotted points, with no live/bucket double counting.
            var previousPlotted: (date: Date, disk: UInt64)?

            for record in generation {
                let date = date(fromMs: record.wallMs)
                if let previous = previousDate {
                    let wallGap = date.timeIntervalSince(previous)
                    // Sleep detection: wall time ran ahead of the uptime clock
                    // (which sleep pauses) by more than jitter could explain.
                    let uptimeGap = previousUptimeMs.map {
                        TimeInterval(record.uptimeMs - $0) / 1000
                    }
                    let slept = uptimeGap.map { wallGap - $0 > sleepSkewSeconds } ?? false
                    if wallGap > gapThresholdSeconds || slept {
                        segment += 1
                    }
                }
                if let previous = previousPid, previous != record.pid {
                    segment += 1
                }
                previousDate = date
                previousUptimeMs = record.uptimeMs
                previousPid = record.pid
                // Markers are events, not samples: a marker's `windowMax` holds
                // the process-LIFETIME peak, so plotting it would draw a spike at
                // every boot and teardown instead of a window maximum.
                guard record.kind == .bucket || record.kind == .live else { continue }
                var diskRateKBs: Double?
                if let previous = previousPlotted, record.diskWritten >= previous.disk {
                    let interval = date.timeIntervalSince(previous.date)
                    if interval > 0 {
                        diskRateKBs = Double(record.diskWritten - previous.disk) / 1024 / interval
                    }
                }
                previousPlotted = (date, record.diskWritten)
                points.append(Point(
                    id: pointId, date: date,
                    footprintMB: megabytes(record.footprint),
                    windowMaxMB: megabytes(record.windowMax),
                    diskWrittenMB: megabytes(record.diskWritten),
                    diskRateKBs: diskRateKBs,
                    segment: segment, pid: record.pid
                ))
                pointId += 1
            }
        }

        // Newest generation is "current" only while the tunnel process is
        // actually alive; otherwise the newest records are a corpse, not a
        // reading — and a mid-transition state has not decided yet.
        var current: Current?
        if tunnelState == .alive, let generation = generations.last {
            let newest = generation[generation.count - 1]
            let first = generation[0]
            current = Current(
                footprintMB: megabytes(newest.footprint),
                windowMaxMB: megabytes(max(newest.windowMax, newest.footprint)),
                peakMB: megabytes(max(newest.lifetimePeak, generation.map { $0.windowMax }.max() ?? 0)),
                headroomMB: newest.limitRemaining > 0 ? megabytes(newest.limitRemaining) : nil,
                startedAt: date(fromMs: first.wallMs),
                pid: newest.pid
            )
        }

        let dayAgo = now.addingTimeInterval(-daySeconds)
        let recent = points.filter { $0.date >= dayAgo }
        let peak24h = recent.map { max($0.footprintMB, $0.windowMaxMB) }.max()
        let restarts = events.filter { $0.kind == .boot && $0.date >= dayAgo }.count
        let lastKill = events.last { $0.kind == .kill }

        return Summary(
            hasTrace: true, points: points, events: events, current: current,
            peak24hMB: peak24h, restarts24h: restarts, lastKill: lastKill
        )
    }

    // MARK: - Helpers

    /// Ring records plus the live slot, when the live slot is newer than the last
    /// bucket of the same generation. After a clean stop the live slot is stale,
    /// and appending it would draw a dead process as still sampling.
    static func mergedRecords(_ trace: NEMemoryTrace.Trace) -> [NEMemoryTrace.Record] {
        var all = trace.records
        guard let live = trace.live else { return all }
        if let last = all.last, live.pid == last.pid, live.uptimeMs > last.uptimeMs {
            all.append(live)
        } else if all.isEmpty {
            all.append(live)
        }
        return all.filter { $0.wallMs > 0 }
    }

    /// Consecutive runs sharing one pid. A pid change is a new process, whether
    /// or not a boot marker landed — a kill during startup can lose the marker.
    static func groupByGeneration(_ records: [NEMemoryTrace.Record]) -> [[NEMemoryTrace.Record]] {
        var generations: [[NEMemoryTrace.Record]] = []
        for record in records {
            if var last = generations.last, last.last?.pid == record.pid {
                last.append(record)
                generations[generations.count - 1] = last
            } else {
                generations.append([record])
            }
        }
        return generations
    }

    static func megabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_048_576
    }

    static func date(fromMs ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
