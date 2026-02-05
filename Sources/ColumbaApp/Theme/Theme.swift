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
enum Theme {
    // MARK: - Colors

    /// Primary accent color (purple/magenta).
    ///
    /// Hex: #9C27B0 (vibrant purple)
    static let accentColor = Color(red: 0.612, green: 0.153, blue: 0.690)

    /// Secondary accent for highlights.
    ///
    /// Hex: #E040FB (magenta/pink)
    static let secondaryAccent = Color(red: 0.878, green: 0.251, blue: 0.984)

    /// Primary background color for dark theme.
    static let backgroundPrimary = Color(red: 0.067, green: 0.067, blue: 0.078)

    /// Secondary background for cards and elevated surfaces.
    static let backgroundSecondary = Color(red: 0.110, green: 0.110, blue: 0.118)

    /// Tertiary background for subtle elevation.
    static let backgroundTertiary = Color(red: 0.157, green: 0.157, blue: 0.173)

    /// Primary text color (high emphasis).
    static let textPrimary = Color.white.opacity(0.87)

    /// Secondary text color (medium emphasis).
    static let textSecondary = Color.white.opacity(0.60)

    /// Disabled/hint text color (low emphasis).
    static let textDisabled = Color.white.opacity(0.38)

    /// Divider/separator color.
    static let divider = Color.white.opacity(0.12)

    /// Success/online color.
    static let success = Color(red: 0.298, green: 0.686, blue: 0.314)

    /// Warning color.
    static let warning = Color(red: 1.0, green: 0.757, blue: 0.027)

    /// Error/offline color.
    static let error = Color(red: 0.957, green: 0.263, blue: 0.212)

    // MARK: - Gradients

    /// Accent gradient for buttons and highlights.
    static let accentGradient = LinearGradient(
        colors: [accentColor, secondaryAccent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Dark gradient for backgrounds.
    static let backgroundGradient = LinearGradient(
        colors: [backgroundPrimary, backgroundSecondary],
        startPoint: .top,
        endPoint: .bottom
    )

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
