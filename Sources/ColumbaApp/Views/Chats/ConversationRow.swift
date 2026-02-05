//
//  ConversationRow.swift
//  Columba-iOS
//
//  Row component for displaying a single conversation in the chats list.
//  Features glass card background, identicon avatar, and favorite button.
//

import SwiftUI

/// Row view for a single conversation in the chats list.
///
/// Displays:
/// - Circular identicon avatar (placeholder with rocket icon)
/// - Peer name (or truncated hash if no display name)
/// - Message preview text
/// - Relative timestamp
/// - Star/favorite button
/// - Glass card background with ultraThinMaterial
struct ConversationRow: View {
    // MARK: - Properties

    /// Conversation to display
    let conversation: Conversation

    /// Callback when favorite button is tapped
    var onFavoriteToggle: () -> Void = {}

    /// Animation state for tap feedback
    @State private var isPressed: Bool = false

    // MARK: - Theme Colors

    private let accentColor = Color(red: 0.404, green: 0.314, blue: 0.643) // #6750A4
    private let cardBackground = Color.white.opacity(0.08)
    private let cardBorder = Color.white.opacity(0.12)

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            avatarView

            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Header row: name and timestamp
                HStack {
                    Text(conversation.peerName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer()

                    Text(conversation.relativeTimestamp)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                }

                // Message preview
                if let preview = conversation.lastMessagePreview {
                    Text(preview)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }

            // Favorite button
            favoriteButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(glassCardBackground)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isPressed)
    }

    // MARK: - Subviews

    /// Identicon avatar with rocket icon placeholder.
    private var avatarView: some View {
        Circle()
            .fill(accentColor)
            .frame(width: 48, height: 48)
            .overlay {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(-45))
            }
            .shadow(color: accentColor.opacity(0.4), radius: 8, x: 0, y: 4)
    }

    /// Favorite/star button with animation.
    private var favoriteButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                onFavoriteToggle()
            }
        } label: {
            Image(systemName: conversation.isFavorite ? "star.fill" : "star")
                .font(.system(size: 20))
                .foregroundColor(conversation.isFavorite ? .yellow : .white.opacity(0.4))
                .contentShape(Rectangle())
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    /// Glass card background with ultra thin material effect.
    private var glassCardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .fill(cardBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(cardBorder, lineWidth: 1)
            }
    }

    // MARK: - Interaction Modifiers

    /// Apply pressed state for tap animation.
    func pressed(_ isPressed: Bool) -> ConversationRow {
        var copy = self
        copy._isPressed = State(initialValue: isPressed)
        return copy
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ZStack {
        // Dark background
        Color.black.ignoresSafeArea()

        VStack(spacing: 12) {
            ConversationRow(
                conversation: Conversation(
                    destinationHash: Data([0xDB, 0x3F, 0xFD, 0x25, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
                    displayName: nil,
                    lastMessageTimestamp: Date().addingTimeInterval(-60),
                    lastMessagePreview: "Hi there!",
                    unreadCount: 0,
                    isFavorite: false
                )
            )

            ConversationRow(
                conversation: Conversation(
                    destinationHash: Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]),
                    displayName: "Alice",
                    lastMessageTimestamp: Date().addingTimeInterval(-3600),
                    lastMessagePreview: "Have you set up your Reticulum node yet?",
                    unreadCount: 2,
                    isFavorite: true
                )
            )
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
#endif
