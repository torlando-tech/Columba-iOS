//
//  ContactCard.swift
//  Columba-iOS
//
//  Glass card component for displaying a contact in the list.
//  Shows identicon avatar, name, hash, badges, signal strength, and status.
//

import SwiftUI
import RNSAPI

/// Glass card component for a contact entry.
///
/// Displays contact information with:
/// - Identicon avatar (circular colorful dot pattern)
/// - Display name or "Unknown Peer"
/// - Truncated identity hash
/// - Badges: "Peer" or "RELAY" (pink background)
/// - Signal strength indicator (bars)
/// - Hop count
/// - Timestamp
/// - Star/favorite button
/// - Online status indicator (green dot)
@available(iOS 17.0, *)
struct ContactCard: View {
    // MARK: - Properties

    /// Contact to display.
    let contact: Contact

    /// Whether to show the interface type icon (for network announces).
    var showInterfaceIcon: Bool = false

    /// Whether this card is the currently selected relay (shows hub badge on avatar).
    var isSelectedRelay: Bool = false

    /// Called when favorite button is tapped.
    var onFavoriteToggle: (() -> Void)?

    /// Called when card is tapped.
    var onTap: (() -> Void)?

    /// Called when "Pin/Unpin Contact" is tapped in context menu.
    var onPin: (() -> Void)?

    /// Called when "View Details" is tapped in context menu.
    var onViewDetails: (() -> Void)?

    /// Called when "Edit Nickname" is tapped in context menu.
    var onEditNickname: (() -> Void)?

    /// Called when "Remove from Contacts" is tapped in context menu.
    var onRemove: (() -> Void)?

    // MARK: - Body

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // Avatar with online indicator
                avatarView

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    // Name row
                    nameRow

                    // Hash row
                    hashRow

                    // Status row
                    statusRow
                }

                Spacer()

                // Right side: signal, hops, favorite
                rightSideView
            }
            .padding(16)
            .background(glassBackground)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if onPin != nil || onViewDetails != nil || onEditNickname != nil || onRemove != nil {
                if let onPin {
                    Button {
                        onPin()
                    } label: {
                        Label(
                            contact.isPinned ? "Unpin Contact" : "Pin Contact",
                            systemImage: contact.isPinned ? "pin.slash" : "pin"
                        )
                    }
                }

                if let onViewDetails {
                    Button {
                        onViewDetails()
                    } label: {
                        Label("View Details", systemImage: "info.circle")
                    }
                }

                if let onEditNickname {
                    Button {
                        onEditNickname()
                    } label: {
                        Label("Edit Nickname", systemImage: "pencil")
                    }
                }

                if let onRemove {
                    Divider()
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove from Contacts", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Avatar View

    private var avatarView: some View {
        ZStack(alignment: .bottomTrailing) {
            // Profile icon (MDI with colors, or identicon fallback)
            ProfileIcon(
                iconName: contact.iconName,
                foregroundColor: contact.iconFgColor,
                backgroundColor: contact.iconBgColor,
                fallbackHash: contact.identityHash,
                size: 48
            )

            // Hub badge for selected relay
            if isSelectedRelay {
                ZStack {
                    Circle()
                        .fill(Theme.accentColor)
                        .frame(width: 20, height: 20)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay(
                    Circle()
                        .stroke(Color(white: 0.15), lineWidth: 2)
                        .frame(width: 20, height: 20)
                )
                .offset(x: 4, y: 4)
            }
            // Online indicator (only when not showing relay badge)
            else if contact.isOnline {
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color(white: 0.15), lineWidth: 2)
                    )
                    .offset(x: 2, y: 2)
            }
        }
    }

    // MARK: - Name Row

    private var nameRow: some View {
        HStack(spacing: 8) {
            Text(contact.resolvedDisplayName)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            // Badge
            contactBadge
        }
    }

    private var contactBadge: some View {
        Group {
            switch contact.badgeType {
            case .relay:
                Text("RELAY")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .cornerRadius(4)
            case .audio:
                Text("Audio")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple)
                    .cornerRadius(4)
            case .node:
                Text("Node")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green)
                    .cornerRadius(4)
            case .peer:
                Text("Peer")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.5))
                    .cornerRadius(4)
            }
        }
    }

    // MARK: - Hash Row

    private var hashRow: some View {
        Text(contact.truncatedHash)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(2)
    }

    // MARK: - Status Row

    private var statusRow: some View {
        HStack(spacing: 8) {
            // Timestamp
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                Text(contact.timeAgo)
                    .font(.caption)
            }
            .foregroundStyle(Theme.textDisabled)
        }
    }

    // MARK: - Right Side View

    private var rightSideView: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Favorite button
            Button {
                onFavoriteToggle?()
            } label: {
                Image(systemName: contact.isFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(contact.isFavorite ? Color.yellow : Color.gray)
            }
            .buttonStyle(.plain)

            // Signal strength
            signalStrengthView

            // Hop count
            Text("\(contact.hopCount) hops")
                .font(.caption)
                .foregroundStyle(Theme.textDisabled)

            // Interface type icon for network announces
            if showInterfaceIcon {
                interfaceIconView
            }
        }
    }

    // MARK: - Signal Strength View

    private var signalStrengthView: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < contact.signalStrength ? signalColor : Color.gray.opacity(0.3))
                    .frame(width: 4, height: CGFloat(6 + index * 3))
            }
        }
    }

    // MARK: - Interface Icon

    @ViewBuilder
    private var interfaceIconView: some View {
        if contact.interfaceIcon == "bluetooth",
           let ch = MaterialDesignIcons.character(for: "bluetooth") {
            Text(String(ch))
                .font(.custom(MaterialDesignIcons.fontName, size: 12))
                .foregroundStyle(.blue.opacity(0.7))
        } else {
            Image(systemName: contact.interfaceIcon)
                .font(.caption)
                .foregroundStyle(Theme.textDisabled)
        }
    }

    private var signalColor: Color {
        switch contact.signalStrength {
        case 0:
            return .red
        case 1:
            return .orange
        case 2:
            return .yellow
        case 3, 4:
            return .green
        default:
            return .gray
        }
    }

    // MARK: - Glass Background

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(ThemeManager.shared.isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(ThemeManager.shared.isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 17.0, *)
#Preview {
    ScrollView {
        VStack(spacing: 12) {
            ContactCard(
                contact: Contact(
                    id: "fc112928258ed5f6b9abd1cf0c8d58f0",
                    displayName: "rns.moscow Propag...",
                    identityHash: Data([0xFC, 0x11, 0x29, 0x28, 0x25, 0x8E, 0xD5, 0xF6, 0xB9, 0xAB, 0xD1, 0xCF, 0x0C, 0x8D, 0x58, 0xF0]),
                    identityHashHex: "fc112928258ed5f6b9abd1cf0c8d58f0",
                    badgeType: .relay,
                    hopCount: 0,
                    signalStrength: 4,
                    timestamp: Date().addingTimeInterval(-480),
                    isOnline: true,
                    isFavorite: true,
                    isRelay: true
                )
            )

            ContactCard(
                contact: Contact(
                    id: "db3ffd2575469a78bff6b7c8c183e32a",
                    displayName: "Torlando - Columba",
                    identityHash: Data([0xDB, 0x3F, 0xFD, 0x25, 0x75, 0x46, 0x9A, 0x78, 0xBF, 0xF6, 0xB7, 0xC8, 0xC1, 0x83, 0xE3, 0x2A]),
                    identityHashHex: "db3ffd2575469a78bff6b7c8c183e32a",
                    badgeType: .peer,
                    hopCount: 3,
                    signalStrength: 3,
                    timestamp: Date().addingTimeInterval(-60),
                    isOnline: true,
                    isFavorite: false,
                    isRelay: false
                ),
                showInterfaceIcon: true
            )

            ContactCard(
                contact: Contact(
                    id: "00e78bccb2ccc8e266a216b1e2d5475f",
                    displayName: nil,
                    identityHash: Data([0x00, 0xE7, 0x8B, 0xCC, 0xB2, 0xCC, 0xC8, 0xE2, 0x66, 0xA2, 0x16, 0xB1, 0xE2, 0xD5, 0x47, 0x5F]),
                    identityHashHex: "00e78bccb2ccc8e266a216b1e2d5475f",
                    badgeType: .peer,
                    hopCount: 5,
                    signalStrength: 1,
                    timestamp: Date(),
                    isOnline: false,
                    isFavorite: false,
                    isRelay: false
                )
            )
        }
        .padding()
    }
    .background(Color(white: 0.1))
}
#endif
