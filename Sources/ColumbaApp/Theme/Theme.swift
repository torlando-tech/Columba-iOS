//
//  Theme.swift
//  ColumbaApp
//
//  Shared theming constants for consistent visual appearance.
//  Provides color palette, glass materials, and style modifiers.
//

import SwiftUI

/// App theming namespace.
///
/// Provides centralized access to colors, materials, and style modifiers.
/// Color properties delegate to `ThemeManager.shared` for dynamic theming.
@available(iOS 17.0, macOS 14.0, *)
enum Theme {
    // MARK: - Dynamic Colors (delegate to ThemeManager)

    /// Primary accent color.
    @MainActor static var accentColor: Color { ThemeManager.shared.accentColor }

    /// Secondary accent for highlights.
    @MainActor static var secondaryAccent: Color { ThemeManager.shared.secondaryAccent }

    /// Primary background color.
    @MainActor static var backgroundPrimary: Color { ThemeManager.shared.backgroundPrimary }

    /// Secondary background for cards and elevated surfaces.
    @MainActor static var backgroundSecondary: Color { ThemeManager.shared.backgroundSecondary }

    /// Tertiary background for subtle elevation.
    @MainActor static var backgroundTertiary: Color { ThemeManager.shared.backgroundTertiary }

    /// Primary text color (high emphasis).
    static let textPrimary = Color.white.opacity(0.87)

    /// Secondary text color (medium emphasis).
    static let textSecondary = Color.white.opacity(0.60)

    /// Disabled/hint text color (low emphasis).
    static let textDisabled = Color.white.opacity(0.38)

    /// Divider/separator color.
    static let divider = Color.white.opacity(0.12)

    /// Success/online color.
    @MainActor static var success: Color { ThemeManager.shared.success }

    /// Warning color.
    @MainActor static var warning: Color { ThemeManager.shared.warning }

    /// Error/offline color.
    @MainActor static var error: Color { ThemeManager.shared.error }

    /// Sent message bubble color.
    @MainActor static var sentBubbleColor: Color { ThemeManager.shared.sentBubbleColor }

    /// Received message bubble color.
    @MainActor static var receivedBubbleColor: Color { ThemeManager.shared.receivedBubbleColor }

    // MARK: - Gradients

    /// Accent gradient for buttons and highlights.
    @MainActor static var accentGradient: LinearGradient { ThemeManager.shared.accentGradient }

    /// Dark gradient for backgrounds.
    @MainActor static var backgroundGradient: LinearGradient { ThemeManager.shared.backgroundGradient }

    // MARK: - Corner Radii

    static let cornerRadiusSmall: CGFloat = 8
    static let cornerRadiusMedium: CGFloat = 12
    static let cornerRadiusLarge: CGFloat = 16
    static let cornerRadiusXLarge: CGFloat = 24

    // MARK: - Shadows

    static let shadowRadius: CGFloat = 8
    static let shadowOpacity: Double = 0.25
}

// MARK: - Glass Material Styles

@available(iOS 17.0, macOS 14.0, *)
extension View {
    /// Applies glass material background with blur effect.
    ///
    /// Creates a frosted glass appearance using ultraThinMaterial.
    func glassBackground() -> some View {
        self
            .background(.ultraThinMaterial)
            .background(Theme.backgroundSecondary.opacity(0.5))
    }

    /// Applies glass material with rounded corners.
    ///
    /// - Parameter cornerRadius: Corner radius for the glass container.
    func glassCard(cornerRadius: CGFloat = Theme.cornerRadiusMedium) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Theme.backgroundSecondary.opacity(0.5))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Theme.divider, lineWidth: 1)
                    }
            }
    }

    /// Applies card style with elevation and shadow.
    ///
    /// - Parameter cornerRadius: Corner radius for the card.
    func cardStyle(cornerRadius: CGFloat = Theme.cornerRadiusMedium) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Theme.backgroundSecondary)
                    .shadow(
                        color: .black.opacity(Theme.shadowOpacity),
                        radius: Theme.shadowRadius,
                        x: 0,
                        y: 4
                    )
            }
    }

    /// Applies accent button style with gradient.
    func accentButtonStyle() -> some View {
        self
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                    .fill(Theme.accentGradient)
            }
    }
}

// MARK: - Font Styles

extension Font {
    /// Large title for screen headers.
    static let screenTitle: Font = .system(size: 28, weight: .bold, design: .rounded)

    /// Section header font.
    static let sectionHeader: Font = .system(size: 13, weight: .semibold, design: .default)

    /// Body text font.
    static let bodyText: Font = .system(size: 16, weight: .regular, design: .default)

    /// Caption/secondary text font.
    static let caption: Font = .system(size: 13, weight: .regular, design: .default)

    /// Small caption font.
    static let captionSmall: Font = .system(size: 11, weight: .regular, design: .default)
}

// MARK: - Color Extension

extension Color {
    /// Create color from hex string.
    ///
    /// Supports formats: "#9C27B0", "9C27B0", "#RGB", "RGB"
    ///
    /// - Parameter hex: Hex color string (3 or 6 characters, with or without #)
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b: Double
        switch hex.count {
        case 3: // RGB (12-bit)
            r = Double((int >> 8) * 17) / 255
            g = Double((int >> 4 & 0xF) * 17) / 255
            b = Double((int & 0xF) * 17) / 255
        case 6: // RRGGBB (24-bit)
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 0
            g = 0
            b = 0
        }
        self.init(red: r, green: g, blue: b)
    }
}
