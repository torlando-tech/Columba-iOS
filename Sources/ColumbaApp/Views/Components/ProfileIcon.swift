//
//  ProfileIcon.swift
//  ColumbaApp
//
//  Displays a profile icon (MDI) with colors, falling back to Identicon.
//  Used everywhere peer avatars appear: ConversationRow, ContactCard, NodeDetailsView.
//

import SwiftUI

/// Displays a profile icon (MDI) with foreground/background colors,
/// falling back to Identicon when no icon is set.
@available(iOS 17.0, macOS 14.0, *)
struct ProfileIcon: View {
    let iconName: String?
    let foregroundColor: String?  // hex RGB (6 chars)
    let backgroundColor: String?  // hex RGB (6 chars)
    let fallbackHash: Data
    let size: CGFloat

    var body: some View {
        if let name = iconName,
           let fg = foregroundColor,
           let bg = backgroundColor,
           let char = MaterialDesignIcons.character(for: name) {
            ZStack {
                Circle()
                    .fill(Color(hexRGB: bg))
                Text(String(char))
                    .font(.custom(MaterialDesignIcons.fontName, size: size * 0.55))
                    .foregroundStyle(Color(hexRGB: fg))
            }
            .frame(width: size, height: size)
        } else {
            Identicon(hash: fallbackHash)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Color hex extension

extension Color {
    /// Create Color from a 6-character hex RGB string (e.g., "FF5733").
    init(hexRGB hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
