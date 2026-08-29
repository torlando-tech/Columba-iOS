//
//  PeerContactSheet.swift
//  ColumbaApp
//
//  Bottom sheet shown when a peer map pin is tapped. Mirrors Android
//  Columba's ContactLocationBottomSheet: 48pt profile icon (dimmed when
//  stale), display name + Stale badge, "Updated …" line, distance and
//  direction from the user, Directions/Message buttons, and a
//  Remove-from-map action for stale peers (a peer that goes quiet
//  without sending CEASE must not leave a pin with no escape hatch).
//

import SwiftUI
#if os(iOS)
import CoreLocation
#endif

#if os(iOS)
@available(iOS 17.0, *)
struct PeerContactSheet: View {
    let peer: PeerLocation
    let userCoordinate: CLLocationCoordinate2D?
    let onDirections: () -> Void
    let onMessage: () -> Void
    let onRemove: () -> Void
    let onDismiss: () -> Void

    @State private var now = Date()

    /// The sheet stays live: a newer telemetry tick for the same peer
    /// refreshes `peer` from MapView's derived binding, and a periodic
    /// tick keeps the "Updated …" line moving while the sheet is open.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var displayName: String {
        peer.displayName ?? peer.shortHash
    }

    private var distanceText: String {
        PeerLocationFormatting.formatDistanceAndDirection(
            userCoordinate: userCoordinate,
            peerCoordinate: peer.coordinate
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Handle bar
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            // Avatar, name, and last updated (Android parity row)
            HStack(spacing: 16) {
                ProfileIcon(
                    iconName: peer.iconAppearance?.iconName,
                    foregroundColor: peer.iconAppearance?.foregroundColor,
                    backgroundColor: peer.iconAppearance?.backgroundColor,
                    fallbackHash: peer.id,
                    size: 48
                )
                .opacity(peer.isStale ? 0.6 : 1.0)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        // `peer_sheet_name` lives on the name Text itself, NOT
                        // on the sheet root. Putting it on the root together
                        // with `.accessibilityElement(children: .contain)`
                        // made the whole sheet one accessibility element: the
                        // container's identifier was inherited by every
                        // descendant (all buttons reported
                        // `peer_sheet_name`) and the buttons' own
                        // identifiers (`peer_sheet_message` etc.) never
                        // surfaced, so Maestro could not address them. The
                        // name Text is the stable element the interop suite
                        // waits on to confirm the sheet presented.
                        Text(displayName)
                            .font(.title3.bold())
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .accessibilityIdentifier("peer_sheet_name")
                        if peer.isStale {
                            Text(String(localized: "Stale"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(PeerLocationFormatting.formatUpdatedTime(peer.lastUpdate, now: now))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            // Distance and direction
            Text(distanceText)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)

            // Action buttons
            HStack(spacing: 12) {
                Button(action: onDirections) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond")
                            .font(.system(size: 16))
                        Text(String(localized: "Directions"))
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.textPrimary.opacity(0.4), lineWidth: 1)
                    )
                    .foregroundStyle(Theme.textPrimary)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("peer_sheet_directions")

                Button(action: onMessage) {
                    HStack(spacing: 8) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 16))
                        Text(String(localized: "Message"))
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("peer_sheet_message")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            // Remove marker (stale peers only - Android parity)
            if peer.isStale {
                Button(action: onRemove) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16))
                        Text(String(localized: "Remove from map"))
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(Theme.error)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .accessibilityIdentifier("peer_sheet_remove")
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
        .background(Theme.backgroundPrimary)
        // No `.accessibilityElement(children: .contain)` + root
        // `accessibilityIdentifier` here: that combination collapses the
        // whole sheet into one accessibility element, hides the buttons'
        // own identifiers, and stamps the root id onto every descendant
        // (verified in the live a11y hierarchy: the Directions/Message
        // rows reported `resource-id: peer_sheet_name` and
        // `peer_sheet_message`/`peer_sheet_directions`/`peer_sheet_remove`
        // were absent). Leave the default `.contain`-ish traversal so each
        // control keeps its own identifier and label.
        .onReceive(ticker) { tick in
            now = tick
        }
        .onAppear {
            now = Date()
        }
    }
}
#endif
