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
    /// Whether the tunnel is up right now. Decides whether the newest trace
    /// records are a live reading or the last words of a killed process.
    let tunnelConnected: Bool
    /// Foreground-only hosting means there is no separate process to measure.
    let hostingMode: NodeHostingMode

    @State private var summary = NEMemoryHistory.Summary()
    @State private var range: MemoryRange = .day
    @State private var hasLoadedOnce = false

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
                explainer
            }
            .padding(20)
        }
        .background(Theme.backgroundPrimary)
        .foregroundStyle(Theme.textPrimary)
        .navigationTitle(String(localized: "Memory Usage"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
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
                        AxisValueLabel(format: .dateTime.hour().day(), centered: false)
                    }
                }
                .frame(height: 220)
                .accessibilityIdentifier("ne_memory_chart")

                Text("Gaps mean nothing was recorded — the device was asleep or the process was gone. Lines are never bridged across them.")
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
            Text("The limit line only appears when iOS reports a remaining budget for this process; it does not always.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
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

    private func formatMB(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f MB", value)
    }

    // MARK: - Loading

    /// Ring read off the main actor: it is a 512 KB file read, cheap, but it must
    /// not run inside the view's body on the main thread.
    private func reload() async {
        let connected = tunnelConnected
        let trace = await Task.detached(priority: .utility) {
            NEMemoryTrace.readAll()
        }.value
        summary = NEMemoryHistory.analyze(trace, tunnelConnected: connected)
        hasLoadedOnce = true
    }
}
