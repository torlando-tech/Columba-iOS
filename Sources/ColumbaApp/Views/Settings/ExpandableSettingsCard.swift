//
//  ExpandableSettingsCard.swift
//  Columba-iOS
//
//  Reusable expandable card component for settings.
//  Features icon, title, optional toggle, and animated expand/collapse.
//

import SwiftUI

/// A reusable expandable settings card with glass material background.
///
/// Displays an icon, title, optional toggle, and chevron indicator.
/// When tapped, smoothly animates expansion to show additional content.
///
/// Usage:
/// ```swift
/// ExpandableSettingsCard(
///     icon: "wifi",
///     title: "Network",
///     isExpanded: $isNetworkExpanded
/// ) {
///     // Expanded content here
/// }
/// ```
@available(iOS 17.0, macOS 14.0, *)
struct ExpandableSettingsCard<Content: View>: View {
    // MARK: - Properties

    /// SF Symbol name for the leading icon.
    let icon: String

    /// Card title text.
    let title: String

    /// Binding to expansion state.
    @Binding var isExpanded: Bool

    /// Optional toggle binding for cards with switch.
    var toggle: Binding<Bool>?

    /// Expanded content builder.
    @ViewBuilder let content: () -> Content

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            headerView
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
        .glassCard()
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accentColor)
                .frame(width: 24, height: 24)

            // Title
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            // Optional toggle
            if let toggle = toggle {
                Toggle("", isOn: toggle)
                    .toggleStyle(AccentToggleStyle())
                    .labelsHidden()
            }

            // Chevron indicator
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Accent Toggle Style

/// Custom toggle style matching the accent color scheme.
@available(iOS 17.0, macOS 14.0, *)
struct AccentToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label

            ZStack {
                // Track
                Capsule()
                    .fill(configuration.isOn ? Theme.accentColor : Theme.backgroundTertiary)
                    .frame(width: 48, height: 28)

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                    .offset(x: configuration.isOn ? 10 : -10)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isOn)
            .onTapGesture {
                configuration.isOn.toggle()
            }
        }
    }
}

// MARK: - Simple Expandable Card (No Toggle)

/// Convenience initializer for cards without toggle.
@available(iOS 17.0, macOS 14.0, *)
extension ExpandableSettingsCard {
    init(
        icon: String,
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self._isExpanded = isExpanded
        self.toggle = nil
        self.content = content
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 17.0, macOS 14.0, *)
#Preview {
    ZStack {
        Theme.backgroundPrimary
            .ignoresSafeArea()

        VStack(spacing: 16) {
            ExpandableSettingsCard(
                icon: "wifi",
                title: "Network",
                isExpanded: .constant(false)
            ) {
                Text("Network content")
                    .foregroundStyle(Theme.textSecondary)
            }

            ExpandableSettingsCard(
                icon: "person.fill",
                title: "Identity",
                isExpanded: .constant(true)
            ) {
                Text("View and share your identity, edit your display name, and manage QR codes for contact sharing.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            ExpandableSettingsCard(
                icon: "bell.fill",
                title: "Notifications",
                isExpanded: .constant(false),
                toggle: .constant(true)
            ) {
                Text("Notification settings")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
#endif
