//
//  IconPickerView.swift
//  ColumbaApp
//
//  Full-screen icon picker for choosing an MDI profile icon with colors.
//  Matches the Kotlin/Android icon picker for Reticulum ecosystem interop.
//

import SwiftUI

/// Icon picker sheet for choosing an MDI profile icon.
///
/// Layout:
/// - Preview: Selected icon at multiple sizes
/// - Color pickers: Preset color circles for FG and BG
/// - Search: Filter icons by name
/// - Icon grid: LazyVGrid organized by category or search results
@available(iOS 17.0, macOS 14.0, *)
struct IconPickerView: View {
    // MARK: - Bindings

    /// Current icon appearance (nil = identicon)
    @Binding var iconAppearance: IconAppearance?

    /// Dismiss action
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var selectedIcon: String = "account"
    @State private var selectedFg: String = "FFFFFF"
    @State private var selectedBg: String = "1E88E5"
    @State private var searchText: String = ""

    // MARK: - Color Presets (matching Kotlin)

    private let fgPresets = [
        "FFFFFF", "000000", "F44336", "E91E63", "9C27B0", "673AB7",
        "3F51B5", "2196F3", "03A9F4", "00BCD4", "009688", "4CAF50",
        "8BC34A", "CDDC39", "FFEB3B", "FFC107", "FF9800", "FF5722",
    ]

    private let bgPresets = [
        "1E88E5", "43A047", "E53935", "8E24AA", "3949AB", "00897B",
        "F4511E", "6D4C41", "546E7A", "D81B60", "5E35B1", "1565C0",
        "00838F", "2E7D32", "F9A825", "EF6C00", "4E342E", "37474F",
    ]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    previewSection
                    colorSection
                    searchSection
                    iconGridSection
                }
                .padding(16)
            }
            .background(Theme.backgroundPrimary)
            .navigationTitle("Choose Icon")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        iconAppearance = IconAppearance(
                            iconName: selectedIcon,
                            foregroundColor: selectedFg,
                            backgroundColor: selectedBg
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            if let existing = iconAppearance {
                selectedIcon = existing.iconName
                selectedFg = existing.foregroundColor
                selectedBg = existing.backgroundColor
            }
        }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(spacing: 12) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                iconPreview(size: 32)
                iconPreview(size: 48)
                iconPreview(size: 72)
            }
            .padding(.vertical, 8)
        }
        .padding(16)
        .glassCard()
    }

    private func iconPreview(size: CGFloat) -> some View {
        Group {
            if let char = MaterialDesignIcons.character(for: selectedIcon) {
                ZStack {
                    Circle()
                        .fill(Color(hexRGB: selectedBg))
                    Text(String(char))
                        .font(.custom(MaterialDesignIcons.fontName, size: size * 0.55))
                        .foregroundStyle(Color(hexRGB: selectedFg))
                }
                .frame(width: size, height: size)
            } else {
                Circle()
                    .fill(Color.gray)
                    .frame(width: size, height: size)
            }
        }
    }

    // MARK: - Color Section

    private var colorSection: some View {
        VStack(spacing: 12) {
            // Foreground color
            VStack(alignment: .leading, spacing: 8) {
                Text("Icon Color")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(fgPresets, id: \.self) { hex in
                            colorCircle(hex: hex, isSelected: hex == selectedFg) {
                                selectedFg = hex
                            }
                        }
                    }
                }
            }

            // Background color
            VStack(alignment: .leading, spacing: 8) {
                Text("Background Color")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(bgPresets, id: \.self) { hex in
                            colorCircle(hex: hex, isSelected: hex == selectedBg) {
                                selectedBg = hex
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    private func colorCircle(hex: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(hexRGB: hex))
                .frame(width: 32, height: 32)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(.white, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search Section

    private var searchSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search icons...", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            // Clear icon button
            Button {
                iconAppearance = nil
                dismiss()
            } label: {
                Text("Clear")
                    .font(.caption)
                    .foregroundStyle(Theme.error)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
    }

    // MARK: - Icon Grid Section

    private var iconGridSection: some View {
        LazyVStack(spacing: 16, pinnedViews: .sectionHeaders) {
            if searchText.isEmpty {
                // Browse by category
                ForEach(MaterialDesignIcons.categories, id: \.name) { category in
                    Section {
                        iconGrid(icons: category.icons)
                    } header: {
                        Text(category.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .background(Theme.backgroundPrimary)
                    }
                }
            } else {
                // Search results
                let filtered = MaterialDesignIcons.allNames.filter {
                    $0.localizedCaseInsensitiveContains(searchText)
                }.prefix(120)
                iconGrid(icons: Array(filtered))
            }
        }
    }

    private func iconGrid(icons: [String]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(icons, id: \.self) { name in
                iconButton(name: name)
            }
        }
    }

    private func iconButton(name: String) -> some View {
        Button {
            selectedIcon = name
        } label: {
            Group {
                if let char = MaterialDesignIcons.character(for: name) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(name == selectedIcon
                                  ? Theme.accentColor.opacity(0.3)
                                  : Color.white.opacity(0.06))
                        Text(String(char))
                            .font(.custom(MaterialDesignIcons.fontName, size: 24))
                            .foregroundStyle(name == selectedIcon
                                             ? Theme.accentColor
                                             : .white.opacity(0.8))
                    }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                        .overlay {
                            Text("?")
                                .foregroundStyle(.white.opacity(0.3))
                        }
                }
            }
            .frame(height: 48)
        }
        .buttonStyle(.plain)
    }
}
