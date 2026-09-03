//
//  CallDetailsView.swift
//  ColumbaApp
//
//  Detail screen for one voice call (issue #167). Pushed from the Voice list.
//  Takes the enriched VoiceCallDisplay (live name/icon) rather than the pure
//  CallHistoryRecord.
//

import SwiftUI
import LXSTSwift   // TelephonyProfile (quality-profile label in the detail view)

@available(iOS 17.0, macOS 14.0, *)
struct CallDetailsView: View {
    let display: VoiceCallDisplay
    let appServices: AppServices
    var onCallAgain: () -> Void

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium
        return f
    }()

    private var peerName: String { display.peerName }

    private func row(_ label: String, _ value: String, monospace: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(.system(size: 14)).foregroundColor(.white.opacity(0.55))
            Spacer()
            (monospace ? Text(value).font(.system(size: 13, design: .monospaced))
                       : Text(value).font(.system(size: 14)))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    ProfileIcon(
                        iconName: display.iconName,
                        foregroundColor: display.iconFgColor,
                        backgroundColor: display.iconBgColor,
                        fallbackHash: display.record.remoteIdentityHashData ?? Data(),
                        size: 48
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(peerName).font(.system(size: 20, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text(display.record.remoteIdentityHash)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                Divider().background(.white.opacity(0.1))
                row("Direction", display.record.direction == .incoming ? "Incoming" : "Outgoing")
                row("Outcome", display.record.outcome?.localizedLabel ?? "In progress")
                if let code = display.record.codecProfileCode,
                   let profile = TelephonyProfile(rawValue: UInt8(code)) {
                    row("Quality profile", profile.displayName)
                }
                row("Attempted", Self.dateTimeFormatter.string(from: display.record.attemptedAt))
                if let r = display.record.ringingAt { row("Ringing", Self.dateTimeFormatter.string(from: r)) }
                if let c = display.record.connectedAt { row("Connected", Self.dateTimeFormatter.string(from: c)) }
                if let e = display.record.endedAt { row("Ended", Self.dateTimeFormatter.string(from: e)) }
                if let d = CallHistoryFormatting.connectedDuration(
                    connected: display.record.connectedAt,
                    ended: display.record.endedAt) {
                    row("Duration", d)
                }
                Divider().background(.white.opacity(0.1))
                row("Local identity", appServices.identity?.hexHash ?? display.record.localIdentityHash,
                    monospace: true)
                row("Remote identity", display.record.remoteIdentityHash, monospace: true)
                Button(action: onCallAgain) {
                    Label("Call again", systemImage: "phone.fill")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(display.record.endedAt == nil)   // don't re-dial a live/unclosed attempt
                .accessibilityIdentifier("call_history_call_again")
                .padding(.top, 8)
            }
            .padding(20)
        }
        .navigationTitle("Call Details")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("call_history_details")
        .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
    }
}

/// Localized display label for each outcome. The raw outcome logic stays in
/// `CallHistoryFormatting`; this only maps to user-facing text.
extension CallOutcome {
    var localizedLabel: String {
        switch self {
        case .connectedEnded: return String(localized: "Connected")
        case .missedIncoming: return String(localized: "Missed")
        case .declinedLocal:  return String(localized: "Declined")
        case .rejectedRemote: return String(localized: "Rejected")
        case .busyRemote:     return String(localized: "Busy")
        case .cancelledLocal: return String(localized: "Cancelled")
        case .notConnected:   return String(localized: "Not connected")
        case .failed:         return String(localized: "Failed")
        case .interrupted:    return String(localized: "Interrupted")
        case .inProgress:     return String(localized: "In progress")
        }
    }
}
