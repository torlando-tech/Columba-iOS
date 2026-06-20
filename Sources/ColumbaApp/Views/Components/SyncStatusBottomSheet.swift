//
//  SyncStatusBottomSheet.swift
//  ColumbaApp
//
//  In-app sheet showing live LXMF propagation-sync progress, mirroring
//  Columba-Android's `SyncStatusBottomSheet`. Driven by
//  `PropagationNodeManager.syncState`; under Model B that state is fed by the NE's
//  sync-state snapshots (the NE owns the router), under the python build by the
//  in-process sync. Backend-agnostic — it just renders whatever `syncState` holds.
//

import SwiftUI
import RNSAPI

/// Bottom-sheet content rendering the current propagation-sync phase: a header, a
/// status row (icon + title + subtitle), and a progress bar while messages download.
@available(iOS 17.0, macOS 14.0, *)
struct SyncStatusBottomSheet: View {
    /// Current sync state (observed from `PropagationNodeManager.syncState`).
    let state: PropagationTransferState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(Theme.accentColor)
                    Text("Propagation Node Sync")
                        .font(.title3.weight(.bold))
                        .foregroundColor(Theme.textPrimary)
                }

                Spacer().frame(height: 24)

                // Status row
                statusRow

                // Progress bar (only while actively receiving with known progress)
                if showProgressBar {
                    Spacer().frame(height: 16)
                    ProgressView(value: min(max(state.progress, 0), 1))
                        .tint(Theme.accentColor)
                    Spacer().frame(height: 8)
                    Text("\(Int((min(max(state.progress, 0), 1)) * 100))%")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Scrolls only when content exceeds the detent (e.g. at large Dynamic Type);
        // otherwise behaves like a static view, so the progress bar and percentage are
        // never clipped at the bottom of the fixed-height sheet.
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        // Color the entire sheet, not just the content. Using `.background(...)` on the
        // content paints an opaque band sized to the VStack inside the system's default
        // glass sheet chrome; `.presentationBackground` is the SwiftUI-correct way to set
        // a sheet's backing surface (iOS 16.4+).
        .presentationBackground(Theme.backgroundPrimary)
    }

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        HStack(alignment: .center, spacing: 16) {
            statusIcon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state.state {
        case .linking, .linked, .transferring:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Theme.accentColor)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(Theme.success)
        case .idle:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24))
                .foregroundColor(Theme.accentColor)
        case .noPath, .linkFailed, .transferFailed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundColor(Theme.error)
        }
    }

    // MARK: - Content

    private var showProgressBar: Bool {
        state.state == .transferring && state.progress > 0
    }

    private var title: String {
        switch state.state {
        case .idle: return "Ready"
        case .linking: return "Connecting"
        case .linked: return "Connected"
        case .transferring: return "Receiving"
        case .complete: return "Download complete"
        case .noPath: return "No path to relay"
        case .linkFailed: return "Connection failed"
        case .transferFailed: return "Sync failed"
        }
    }

    private var subtitle: String {
        switch state.state {
        case .idle:
            return "Not currently syncing"
        case .linking:
            return "Establishing secure connection…"
        case .linked:
            return "Connected, preparing request…"
        case .transferring:
            return "Downloading messages…"
        case .complete:
            return state.receivedMessages > 0
                ? "\(state.receivedMessages) new message\(state.receivedMessages == 1 ? "" : "s")"
                : "No new messages"
        case .noPath:
            return state.errorDescription ?? "Couldn't find a route to the propagation node"
        case .linkFailed, .transferFailed:
            return state.errorDescription ?? "Please try again"
        }
    }
}
