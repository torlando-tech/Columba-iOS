//
//  CallHistoryFormatting.swift
//  ColumbaApp
//
//  Pure, dependency-free presentation helpers for call history. Shared by the
//  Chats Voice segment card and the Call Details screen so the outcome/label/
//  duration semantics have exactly one source of truth (DRY). Unit-tested in
//  CallHistoryFormattingTests.
//

import Foundation
import LXSTSwift

/// Call direction relative to the local identity.
public enum CallHistoryDirection: String, Sendable {
    case incoming
    case outgoing
}

/// Reduced, direction-aware call outcome (subset of the Android vocabulary the
/// Python-LXST backend can actually produce on iOS).
public enum CallOutcome: String, Sendable, Equatable {
    case connectedEnded
    case missedIncoming
    case declinedLocal
    case rejectedRemote
    case busyRemote
    case cancelledLocal
    case notConnected
    case failed
    case interrupted
    case inProgress
}

public enum CallHistoryFormatting {

    // MARK: day grouping

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Stable calendar-day bucket key for a timestamp (local calendar).
    public static func dayKey(_ timestamp: Date, now: Date = Date()) -> String {
        dayKeyFormatter.string(from: timestamp)
    }

    /// "Today" / "Yesterday" / locale MEDIUM date.
    public static func dayLabel(_ timestamp: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        let startTarget = cal.startOfDay(for: timestamp)
        if startTarget == startToday { return "Today" }
        if startTarget == cal.date(byAdding: .day, value: -1, to: startToday) {
            return "Yesterday"
        }
        return mediumDateFormatter.string(from: timestamp)
    }

    // MARK: duration

    public static let unavailable = "Unavailable"

    /// mm:ss from components.
    public static func duration(minutes: Int, seconds: Int) -> String {
        String(format: "%d:%02d", minutes, seconds)
    }

    /// Connected-only duration. Returns nil when there was no connection (a
    /// never-connected call shows NO duration, not 0:00), or "Unavailable" when
    /// the milestones are contradictory.
    public static func connectedDuration(connected: Date?, ended: Date?) -> String? {
        guard let connected else { return nil }
        let end = ended ?? Date()
        if end < connected { return unavailable }
        let seconds = Int(end.timeIntervalSince(connected).rounded())
        return duration(minutes: seconds / 60, seconds: seconds % 60)
    }

    // MARK: outcome

    /// Deterministic, direction-aware outcome from the closed LXST `CallEndReason`
    /// set. This is the SINGLE source of truth for how a terminal reason becomes a
    /// user-facing outcome.
    ///
    /// `wasConnected` (== `connectedAt != nil`) is the decider, exactly like the
    /// Android DAO: a call that reached the connection milestone finalizes as
    /// `.connectedEnded` for ANY terminal reason except a genuine mid-call transport
    /// drop (`.linkClosed` → `.interrupted`). `CallEndReason` only disambiguates
    /// calls that NEVER connected.
    public static func outcome(direction: CallHistoryDirection,
                               wasConnected: Bool,
                               reason: CallEndReason) -> CallOutcome {
        if wasConnected {
            return reason == .linkClosed ? .interrupted : .connectedEnded
        }
        switch direction {
        case .incoming:
            switch reason {
            case .localHangup, .rejected: return .declinedLocal
            case .busy, .connectTimeout: return .failed
            case .ringTimeout, .remoteHangup: return .missedIncoming
            case .linkClosed: return .interrupted
            }
        case .outgoing:
            switch reason {
            case .rejected: return .rejectedRemote
            case .busy: return .busyRemote
            case .ringTimeout, .connectTimeout, .remoteHangup: return .notConnected
            case .linkClosed: return .interrupted
            case .localHangup: return .cancelledLocal   // caller gave up pre-connect
            }
        }
    }

    /// Localized outcome label (localize at the view layer; keep this pure by
    /// returning the raw case so tests assert on it directly).
    public static func outcomeKey(_ outcome: CallOutcome) -> String {
        outcome.rawValue
    }

    // MARK: time (card)

    private static let cardTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Short locale time for the card row ("3:42 PM"). Used by the Voice history
    /// list (Task 4); lives here so the formatter has one home.
    public static func cardTime(_ date: Date) -> String {
        cardTimeFormatter.string(from: date)
    }

    // MARK: peer name

    /// Display name with a "Peer <first 8 hex upper>" fallback, matching the
    /// existing `Conversation.peerName` convention.
    public static func peerName(displayName: String?, remoteIdentityHash: Data) -> String {
        if let name = displayName, !name.isEmpty { return name }
        let hex = remoteIdentityHash
            .prefix(4)
            .map { String(format: "%02X", $0) }
            .joined()
        return "Peer \(hex)"
    }
}
