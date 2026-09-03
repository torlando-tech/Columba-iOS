//
//  VoiceHistoryView.swift
//  ColumbaApp
//
//  The Voice segment of the Chats screen (issue #167): a day-grouped list of
//  call-history cards, each enriched with the live conversation name/icon.
//  Tapping a card pushes CallDetailsView.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct VoiceHistoryView: View {
    @Bindable var viewModel: ChatsViewModel
    var appServices: AppServices
    var onCallAgain: (VoiceCallDisplay) -> Void
    var onClear: () -> Void

    private var groupedDisplays: [(key: String, label: String, items: [VoiceCallDisplay])] {
        let now = Date()
        let byDay = Dictionary(grouping: viewModel.voiceRecords) {
            CallHistoryFormatting.dayKey($0.record.attemptedAt, now: now)
        }
        return byDay
            .sorted { $0.value[0].record.attemptedAt > $1.value[0].record.attemptedAt }
            .map { (key: $0.key,
                   label: CallHistoryFormatting.dayLabel($0.value[0].record.attemptedAt, now: now),
                   items: $0.value) }
    }

    var body: some View {
        Group {
            if viewModel.voiceIsLoading && viewModel.voiceRecords.isEmpty {
                loadingState
            } else if viewModel.voiceRecords.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 12) { ProgressView() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "phone")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Theme.accentColor)
            Text("No Calls Yet")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Incoming and outgoing voice calls will appear here.")
                .font(.system(size: 15))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(groupedDisplays, id: \.key) { group in
                    Text(group.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                    ForEach(group.items) { item in
                        NavigationLink {
                            CallDetailsView(
                                display: item,
                                appServices: appServices,
                                onCallAgain: { onCallAgain(item) }
                            )
                        } label: {
                            CallHistoryCard(
                                display: item,
                                isActive: item.record.id == viewModel.activeCallAttemptId
                                          && item.record.endedAt == nil
                            )
                        }
                        .buttonStyle(ConversationRowButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 16)
        }
        .refreshable { await viewModel.loadVoiceHistory() }
    }
}

/// One row of the Voice list: profile icon, direction arrow, peer name,
/// direction · outcome, duration, and time.
@available(iOS 17.0, macOS 14.0, *)
struct CallHistoryCard: View {
    let display: VoiceCallDisplay
    let isActive: Bool

    private var directionLabel: String {
        display.record.direction == .incoming ? "Incoming" : "Outgoing"
    }

    /// Outcome text: the single source of truth is `CallOutcome.localizedLabel`
    /// (CallDetailsView uses the same). Only the two non-enum states are handled
    /// here — a live in-progress call, and a record whose outcome hasn't been
    /// written yet (crash before the end callback landed).
    private var outcomeLabel: String {
        if isActive { return CallOutcome.inProgress.localizedLabel }
        return display.record.outcome?.localizedLabel
            ?? String(localized: "Recovering call status")
    }

    private var severityColor: Color {
        if isActive { return Theme.accentColor }
        switch display.record.outcome {
        case .missedIncoming: return .red
        case .failed, .interrupted: return .orange
        default: return .secondary
        }
    }

    private var durationText: String? {
        CallHistoryFormatting.connectedDuration(
            connected: display.record.connectedAt,
            ended: display.record.endedAt)
    }

    var body: some View {
        HStack(spacing: 12) {
            ProfileIcon(
                iconName: display.iconName,
                foregroundColor: display.iconFgColor,
                backgroundColor: display.iconBgColor,
                fallbackHash: display.record.remoteIdentityHashData ?? Data(),
                size: 40
            )
            Image(systemName: display.record.direction == .incoming
                  ? "arrow.down.left" : "arrow.up.right")
                .foregroundColor(severityColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.peerName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .accessibilityIdentifier("call_history_peer_name")
                Text("\(directionLabel) · \(outcomeLabel)")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .accessibilityIdentifier("call_history_outcome")
                if let d = durationText {
                    Text(d).font(.system(size: 13)).foregroundColor(.white.opacity(0.5))
                }
                Text(CallHistoryFormatting.cardTime(display.record.attemptedAt))
                    .font(.system(size: 13)).foregroundColor(.white.opacity(0.5))
                    .accessibilityIdentifier("call_history_time")
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("call_history_card")
        .contentShape(Rectangle())
    }
}
