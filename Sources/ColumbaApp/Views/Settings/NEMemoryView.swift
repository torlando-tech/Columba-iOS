//
//  NEMemoryView.swift
//  ColumbaApp
//
//  Memory usage of the background transport process, charted from the trace the
//  Network Extension writes about itself.
//
//  Reachable from Settings → Reticulum Hosting. The numbers are the NE's own
//  `phys_footprint` samples — the same metric iOS enforces its kill ceiling on —
//  so a value here is directly comparable to "how close was it to being killed".
//  The app cannot measure the NE from the outside (separate sandboxed process),
//  which is why the series stops whenever the NE is not running, and why a kill
//  is inferred from a missing clean-stop marker rather than reported by the OS.
//

import SwiftUI
import Charts

@available(iOS 17.0, macOS 14.0, *)
struct NEMemoryView: View {
    /// The tunnel manager, observed live: the kill card and the "now" reading
    /// must follow the tunnel's actual state while the page is open, not the
    /// state at construction time (a page opened during `.connecting` must not
    /// show "stopped unexpectedly" for a process that is recording right now).
    /// `nil` (no tunnel configured) behaves like a gone tunnel.
    let tunnel: TunnelManager?
    /// Foreground-only hosting means there is no separate process to measure.
    let hostingMode: NodeHostingMode

    @State private var summary = NEMemoryHistory.Summary()
    @State private var range: MemoryRange = .day
    /// The app's OWN footprint — a different process from the one charted, and
    /// the only half of the picture iOS lets the app measure directly.
    @State private var appFootprintMB: Double? = nil

    enum MemoryRange: String, CaseIterable, Identifiable {
        case hour = "1 h"
        case day = "24 h"
        case week = "7 d"

        var id: String { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .hour: return 3_600
            case .day: return 86_400
            case .week: return 604_800
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if hostingMode == .foreground {
                    foregroundModeNotice
                }
                killCard
                statusCard
                statsRow
                rangePicker
                chartCard
                diskChartCard
                explainer
            }
            .padding(20)
        }
        .background(Theme.backgroundPrimary)
        .foregroundStyle(Theme.textPrimary)
        .navigationTitle(String(localized: "Memory Usage"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reloadLoop() }
        .refreshable { await reload() }
        .onChange(of: tunnel?.status) { _, _ in Task { await reload() } }
    }

    // MARK: - Sections

    private var foregroundModeNotice: some View {
        Label {
            Text("Foreground-only hosting is active, so there is no separate background process to measure. Switch to background hosting to record this data.")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.footnote)
        .foregroundStyle(Theme.textSecondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    /// The headline answer to "how much was it using when iOS killed it".
    @ViewBuilder private var killCard: some View {
        if let kill = summary.lastKill {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Stopped unexpectedly")
                        .font(.headline)
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                }
                .foregroundStyle(Color.red)

                Text("Last recorded \(formatMB(kill.lastSeenMB)), peak \(formatMB(kill.peakMB)) — \(kill.date, format: .relative(presentation: .named))")
                    .font(.subheadline)
                    .accessibilityIdentifier("ne_memory_killed_card")

                if let headroom = kill.headroomMB {
                    Text("\(formatMB(headroom)) of headroom was left at the last sample.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let disk = kill.diskWrittenMB {
                    Text("It wrote \(String(format: "%.1f", disk)) MB to disk during its run — the daily budget iOS enforces on background processes is \(String(format: "%.1f", Double(NEMemoryHistory.dailyDiskWriteBudgetBytes) / 1_048_576)) MB.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }

                Text("Columba infers this from the trace ending with no clean stop. iOS does not report memory kills to apps, and a memory kill delivers no callback at all.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let current = summary.current {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatMB(current.footprintMB))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .accessibilityIdentifier("ne_memory_current")
                    Text("now").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if let headroom = current.headroomMB {
                        Text("\(formatMB(headroom)) left")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Text("Running for \(current.startedAt, format: .relative(presentation: .named))")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            } else if summary.hasTrace {
                Text("Not running").font(.title3.weight(.semibold))
                Text("The background transport is stopped, so nothing is being recorded right now. The history below is what it wrote before it stopped.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if let last = summary.events.last, case let .cleanStop(reason) = last.kind {
                    Text("Teardown reason: \(NEMemoryHistory.stopReasonName(reason)) (\(reason))")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text("No data yet").font(.title3.weight(.semibold))
                Text("Enable background hosting and leave it running for a minute; the first samples appear here.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            stat(title: "Peak (24 h)", value: formatMB(summary.peak24hMB))
            stat(title: "Restarts (24 h)", value: "\(summary.restarts24h)")
            stat(title: "Samples", value: "\(summary.points.count)")
        }
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(.body, design: .rounded).weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    private var rangePicker: some View {
        Picker(String(localized: "Range"), selection: $range) {
            ForEach(MemoryRange.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: range) { _, _ in
            Task { await reload() }
        }
    }

    @ViewBuilder private var chartCard: some View {
        if visiblePoints.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No samples in this range").font(.subheadline)
                Text("Try a wider range, or let the background transport run longer.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Chart {
                    ForEach(visiblePoints) { point in
                        if point.windowMaxMB > point.footprintMB {
                            // The spike envelope: what the process peaked at INSIDE
                            // the sample window. Jetsam acts on the peak, not on the
                            // value the window happened to end at, so a chart of the
                            // closing value alone would hide the thing that kills it.
                            AreaMark(
                                x: .value("Time", point.date),
                                yStart: .value("Footprint", point.footprintMB),
                                yEnd: .value("Window max", point.windowMaxMB),
                                series: .value("Run", "\(point.segment)")
                            )
                            .foregroundStyle(Theme.accentColor.opacity(0.22))
                            .interpolationMethod(.linear)
                        }
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Memory", point.footprintMB),
                            series: .value("Run", "\(point.segment)")
                        )
                        .foregroundStyle(Theme.accentColor)
                        .interpolationMethod(.linear)
                    }
                    if let limit = limitLineMB {
                        RuleMark(y: .value("iOS limit", limit))
                            .foregroundStyle(Color.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("iOS limit")
                                    .font(.caption2)
                                    .foregroundStyle(Color.orange)
                            }
                    }
                    ForEach(killEvents) { event in
                        RuleMark(x: .value("Stopped", event.date))
                            .foregroundStyle(Color.red.opacity(0.75))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    }
                }
                .chartYAxisLabel("MB", position: .leading)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().day())
                    }
                }
                .frame(height: 220)
                .accessibilityIdentifier("ne_memory_chart")

                Text("The line is the footprint at the end of each sample window; the shaded band is the highest it reached inside that window. Gaps mean nothing was recorded — the device was asleep or the process was gone. Lines are never bridged across them.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    /// Disk-write rate vs the budget the OS enforces, expressed as a rate. The
    /// y-value is the average over each sample window, so bursts and idle gaps
    /// are both visible; the dashed line is the rate that stays inside the
    /// daily write budget when sustained. (A cumulative chart against the fixed
    /// daily budget was tried first: a multi-day healthy run crosses the line
    /// and reads as a breach, because the budget renews daily — rate does not
    /// have that problem.)
    @ViewBuilder private var diskChartCard: some View {
        if !visiblePoints.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Disk writes").font(.headline)
                Chart {
                    ForEach(visiblePoints) { point in
                        // A point with no rate (segment start, or a failed
                        // probe) plots nothing rather than a fake zero.
                        if let rate = point.diskRateKBs {
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Rate", rate),
                                series: .value("Run", "\(point.segment)")
                            )
                            .foregroundStyle(Theme.accentColor)
                            .interpolationMethod(.linear)
                        }
                    }
                    RuleMark(y: .value("Budget rate", diskBudgetKBs))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("daily average")
                                .font(.caption2)
                                .foregroundStyle(Color.orange)
                        }
                }
                .chartYAxisLabel("KB/s", position: .leading)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().day())
                    }
                }
                .frame(height: 140)
                .accessibilityIdentifier("ne_disk_chart")

                Text("How fast the background transport writes to disk, averaged over each sample window. The dashed line is the average rate that stays inside the per-day write budget iOS enforces (12,137 KB/day); bursts above it are normal — what kills the process is sustaining more than that over a day.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About this data").font(.headline)
            Text("Memory is the process footprint iOS charges against its per-process limit, sampled once a second by the background transport itself and kept in a rolling window of a few days. It includes the Reticulum runtime that runs inside that process.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Text("Recent iOS builds enforce a ceiling of roughly 50 MB on this class of process; the exact number is only visible in the kernel log, so the limit line appears only when iOS also reports a remaining budget, which it does not always do here.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            if let appFootprintMB {
                Text("Columba's own interface process is using \(formatMB(appFootprintMB)) right now. The chart is the background transport process only: iOS keeps the two apart, and an app cannot read another process's memory.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Derived data

    private var visiblePoints: [NEMemoryHistory.Point] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return summary.points.filter { $0.date >= cutoff }
    }

    private var killEvents: [NEMemoryHistory.Event] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return summary.events.filter { $0.kind == .kill && $0.date >= cutoff }
    }

    /// Footprint + reported headroom = the ceiling iOS is enforcing right now.
    /// Derived rather than hardcoded: the per-process limit varies by device and
    /// iOS version, and is only knowable when the OS reports remaining budget.
    private var limitLineMB: Double? {
        guard let current = summary.current, let headroom = current.headroomMB else { return nil }
        let limit = current.footprintMB + headroom
        // A zero/near-zero headroom reading means iOS reported no usable limit.
        return limit > current.footprintMB + 1 ? limit : nil
    }

    /// The daily disk-write budget the OS enforces on this process class,
    /// expressed as an average rate (12,137 KB over 86,400 s ≈ 0.14 KB/s).
    private var diskBudgetKBs: Double {
        Double(NEMemoryHistory.dailyDiskWriteBudgetBytes) / 1024 / 86_400
    }

    private func formatMB(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f MB", value)
    }

    // MARK: - Loading

    /// Ring read off the main actor: it is a 512 KB file read, cheap, but it must
    /// not run inside the view's body on the main thread.
    private func reload() async {
        let state = tunnel.map { NEMemoryHistory.TunnelState($0.status) } ?? .gone
        // Sampling our own footprint is one syscall; do it on the main actor
        // rather than paying an hop for it.
        appFootprintMB = Double(MemoryFootprint.sample().footprint) / 1_048_576
        let trace = await Task.detached(priority: .utility) {
            NEMemoryTrace.readAll()
        }.value
        summary = NEMemoryHistory.analyze(trace, tunnelState: state)
    }

    /// Keep the "now" reading and the kill attribution current while the page
    /// is visible: the ring grows every second and the tunnel can start, die,
    /// or restart at any moment. `.refreshable` and `.onChange` cover the
    /// explicit triggers; this covers everything else.
    private func reloadLoop() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
