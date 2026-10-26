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

    static let daySeconds: TimeInterval = 86_400

    // MARK: - Analysis

    /// - Parameter tunnelConnected: whether the VPN/NE is up right now. Decides
    ///   the one ambiguous case — a newest generation with no stop marker.
    static func analyze(
        _ trace: NEMemoryTrace.Trace,
        tunnelConnected: Bool,
        now: Date = Date()
    ) -> Summary {
        let merged = mergedRecords(trace)
        guard !merged.isEmpty else { return Summary(hasTrace: trace.live != nil || !trace.records.isEmpty) }

        let generations = groupByGeneration(merged)
        var events: [Event] = []
        var points: [Point] = []
        var segment = 0
        var previousDate: Date?
        var previousPid: UInt32?
        var eventId = 0
        var pointId = 0

        for (index, generation) in generations.enumerated() {
            let last = generation[generation.count - 1]
            let endedCleanly = last.kind == .stop
            let isLatestGeneration = index == generations.count - 1
            // No stop marker + (a newer generation exists, or the tunnel is down
            // now) ⇒ the process was killed. A newer generation is itself proof:
            // iOS only relaunches the NE after it tore the previous one down.
            let killed = !endedCleanly && (!isLatestGeneration || !tunnelConnected)

            if let first = generation.first, first.kind == .boot {
                events.append(Event(
                    id: eventId, date: date(fromMs: first.wallMs), kind: .boot,
                    lastSeenMB: nil, peakMB: nil, headroomMB: nil
                ))
                eventId += 1
            }

            if killed {
                // The best number for "what was it using when it got killed":
                // the last footprint it wrote, and the peak it reached — the
                // latter from `ledger_phys_footprint_peak`, which catches spikes
                // that fell between samples and so is never under-reported.
                let lastSeen = generation.map { $0.footprint }.max() ?? 0
                let peak = max(
                    generation.map { $0.lifetimePeak }.max() ?? 0,
                    generation.map { $0.windowMax }.max() ?? 0
                )
                events.append(Event(
                    id: eventId, date: date(fromMs: last.wallMs), kind: .kill,
                    lastSeenMB: megabytes(lastSeen),
                    peakMB: peak > 0 ? megabytes(peak) : nil,
                    headroomMB: last.limitRemaining > 0 ? megabytes(last.limitRemaining) : nil
                ))
                eventId += 1
            } else if endedCleanly {
                events.append(Event(
                    id: eventId, date: date(fromMs: last.wallMs),
                    kind: .cleanStop(reason: Int(last.reason)),
                    lastSeenMB: megabytes(last.footprint),
                    peakMB: last.lifetimePeak > 0 ? megabytes(last.lifetimePeak) : nil,
                    headroomMB: last.limitRemaining > 0 ? megabytes(last.limitRemaining) : nil
                ))
                eventId += 1
            }

            for record in generation {
                let date = date(fromMs: record.wallMs)
                if let previous = previousDate,
                   date.timeIntervalSince(previous) > gapThresholdSeconds {
                    segment += 1
                }
                if let previous = previousPid, previous != record.pid {
                    segment += 1
                }
                previousDate = date
                previousPid = record.pid
                // Markers are events, not samples: a marker's `windowMax` holds
                // the process-LIFETIME peak, so plotting it would draw a spike at
                // every boot and teardown instead of a window maximum.
                guard record.kind == .bucket || record.kind == .live else { continue }
                points.append(Point(
                    id: pointId, date: date,
                    footprintMB: megabytes(record.footprint),
                    windowMaxMB: megabytes(record.windowMax),
                    segment: segment, pid: record.pid
                ))
                pointId += 1
            }
        }

        // Newest generation is "current" only while the tunnel is actually up;
        // otherwise the newest records are a corpse, not a reading.
        var current: Current?
        if tunnelConnected, let generation = generations.last {
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
