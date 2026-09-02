//
//  MyIdentityView.swift
//  Columba-iOS
//
//  Full identity screen showing display name, QR code, and sharing options.
//  Matches Android Columba "My Identity" screen design.
//

import SwiftUI
import RNSAPI
import CoreImage.CIFilterBuiltins

#if canImport(UIKit)
import UIKit
#endif

/// Full identity management screen.
///
/// Displays:
/// - Display Name & Identity card with editable text field
/// - Save and View QR buttons
/// - Identity hash (copyable)
/// - Profile Icon card with identicon preview
/// - Share Your Identity card with QR code
/// - Full Screen and Share buttons
/// - Show Advanced expandable section
@available(iOS 17.0, macOS 14.0, *)
struct MyIdentityView: View {
    // MARK: - Properties

    @Bindable var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false
    @State private var showQRFullScreen = false
    @State private var showShareSheet = false
    @State private var showIconPicker = false
    @State private var copiedToClipboard = false

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Display Name & Identity Card
                displayNameCard

                // Profile Icon Card
                profileIconCard

                // Share Your Identity Card
                shareIdentityCard

                // Show Advanced
                advancedCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.backgroundPrimary)
        .navigationTitle("My Identity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $showQRFullScreen) {
            QRCodeFullScreenView(
                qrCodeString: viewModel.identity.qrCodeString,
                displayName: viewModel.identity.resolvedDisplayName
            )
        }
        .sheet(isPresented: $showShareSheet) {
            if let qrImage = generateQRCodeImage() {
                ShareSheet(items: [qrImage])
            }
        }
        .sheet(isPresented: $showIconPicker) {
            IconPickerView(iconAppearance: Binding(
                get: { viewModel.iconAppearance },
                set: { newValue in
                    Task { await viewModel.updateIconAppearance(newValue) }
                }
            ))
        }
        #endif
    }

    // MARK: - Display Name Card

    private var displayNameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "person.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accentColor)

                Text("Display Name & Identity")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            // Description
            Text("Your display name is shown to other peers when you send announces and messages.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            // Current identity info. Show the *resolved* name - what announce
            // actually broadcasts - so this label can never diverge from what
            // peers receive (an empty custom name announces as the default).
            HStack {
                Text("Current:")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Text(viewModel.identity.resolvedDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accentColor)
            }

            Text("Default: \(SettingsRepository.defaultDisplayName)")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            // Text field
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom Display Name")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                TextField("Enter display name", text: $viewModel.identity.displayName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(12)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
            }

            // Save and View QR buttons
            HStack(spacing: 12) {
                Button(action: {
                    Task {
                        await viewModel.saveDisplayName()
                    }
                    #if os(iOS)
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                    #endif
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 14))
                        Text("Save")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(viewModel.hasUnsavedChanges ? Theme.textPrimary : Theme.textDisabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
                .disabled(!viewModel.hasUnsavedChanges)

                Button(action: { showQRFullScreen = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 14))
                        Text("View QR")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
            }

            Divider()
                .background(Theme.divider)

            // Identity Hash
            VStack(alignment: .leading, spacing: 8) {
                Text("Identity Hash")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                Button(action: {
                    viewModel.copyIdentityHash()
                    copiedToClipboard = true
                    #if os(iOS)
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    #endif

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedToClipboard = false
                    }
                }) {
                    HStack {
                        Text(viewModel.identity.identityHash)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(copiedToClipboard ? Theme.success : Theme.textSecondary)
                    }
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Profile Icon Card

    private var profileIconCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accentColor)

                Text("Profile Icon")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            // Description
            Text("Customize your profile icon that others will see. This is compatible with Sideband and other Reticulum apps.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            // Current icon preview
            HStack(spacing: 12) {
                if let icon = viewModel.iconAppearance,
                   let char = MaterialDesignIcons.character(for: icon.iconName) {
                    // Show MDI icon
                    ZStack {
                        Circle()
                            .fill(Color(hexRGB: icon.backgroundColor))
                        Text(String(char))
                            .font(.custom(MaterialDesignIcons.fontName, size: 26))
                            .foregroundStyle(Color(hexRGB: icon.foregroundColor))
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom Icon")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)

                        Text(icon.iconName)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    // Identicon fallback
                    SettingsIdenticonView(hash: viewModel.identity.identityHash)
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Using Identicon")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)

                        Text("Auto-generated from your identity")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Spacer()
            }

            // Choose Custom Icon button
            Button(action: { showIconPicker = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "face.smiling.inverse")
                        .font(.system(size: 14, weight: .medium))
                    Text("Choose Custom Icon")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            }
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Share Identity Card

    private var shareIdentityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "qrcode")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accentColor)

                Text("Share your contact info")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            // QR Code
            HStack {
                Spacer()

                SettingsQRCodeView(string: viewModel.identity.qrCodeString)
                    .frame(width: 180, height: 180)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))

                Spacer()
            }

            // Full Screen and Share buttons
            HStack(spacing: 12) {
                Button(action: { showQRFullScreen = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14))
                        Text("Full Screen")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }

                Button(action: { showShareSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                        Text("Share")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Advanced Card

    private var advancedCard: some View {
        VStack(spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showAdvanced.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accentColor)
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))

                    Text("Show Advanced")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accentColor)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            if showAdvanced {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .background(Theme.divider)

                    Text("Cryptographic identity details. Tap a value to copy.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    if !viewModel.identity.identityHash.isEmpty {
                        advancedCopyableRow(title: "Identity Hash", value: viewModel.identity.identityHash)
                    }
                    if !viewModel.identity.destinationHash.isEmpty {
                        advancedCopyableRow(title: "Destination Hash (LXMF)", value: viewModel.identity.destinationHash)
                    }
                    if !viewModel.identity.publicKeyHex.isEmpty {
                        advancedCopyableRow(title: "Public Key", value: viewModel.identity.publicKeyHex)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
        .glassCard()
    }

    private func advancedRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func advancedCopyableRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            Button {
                #if os(iOS)
                UIPasteboard.general.string = value
                #endif
            } label: {
                HStack {
                    Text(value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: - QR Code Generation

    #if os(iOS)
    private func generateQRCodeImage() -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(viewModel.identity.qrCodeString.utf8)

        guard let outputImage = filter.outputImage else { return nil }

        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
    #endif
}

// MARK: - QR Code View (Settings-specific to avoid naming conflicts)

/// Generates and displays a QR code from a string.
@available(iOS 17.0, macOS 14.0, *)
struct SettingsQRCodeView: View {
    let string: String

    @State private var cachedImage: CGImage?

    var body: some View {
        Group {
            if let cgImage = cachedImage {
                #if os(iOS)
                Image(uiImage: UIImage(cgImage: cgImage))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                #else
                Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                #endif
            } else {
                Rectangle()
                    .fill(Theme.backgroundTertiary)
            }
        }
        .task(id: string) {
            cachedImage = Self.generateQRCode(from: string)
        }
    }

    private static func generateQRCode(from string: String) -> CGImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)

        guard let outputImage = filter.outputImage else { return nil }

        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        return context.createCGImage(scaledImage, from: scaledImage.extent)
    }
}

// MARK: - QR Code Full Screen View

#if os(iOS)
/// Full screen QR code display for easy scanning.
@available(iOS 17.0, *)
struct QRCodeFullScreenView: View {
    let qrCodeString: String
    let displayName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                SettingsQRCodeView(string: qrCodeString)
                    .frame(width: 280, height: 280)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))

                Text("Scan to add \(displayName.isEmpty ? "peer" : displayName)")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                Button(action: { dismiss() }) {
                    Text("Close")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
    }
}
#endif

// MARK: - Identicon View (Settings-specific to avoid naming conflicts)

/// Generates a deterministic identicon from a hash string.
@available(iOS 17.0, macOS 14.0, *)
struct SettingsIdenticonView: View {
    let hash: String

    private var colors: [Color] {
        // Generate colors from hash
        let hashData = hash.utf8.map { $0 }
        guard hashData.count >= 6 else {
            return [Theme.accentColor, Theme.secondaryAccent]
        }

        let hue1 = Double(hashData[0]) / 255.0
        let hue2 = Double(hashData[1]) / 255.0
        let hue3 = Double(hashData[2]) / 255.0

        return [
            Color(hue: hue1, saturation: 0.7, brightness: 0.8),
            Color(hue: hue2, saturation: 0.6, brightness: 0.9),
            Color(hue: hue3, saturation: 0.8, brightness: 0.7)
        ]
    }

    private var pattern: [[Bool]] {
        // Generate 5x5 pattern from hash (mirrored)
        let hashData = hash.utf8.map { $0 }
        var grid: [[Bool]] = Array(repeating: Array(repeating: false, count: 5), count: 5)

        for row in 0..<5 {
            for col in 0..<3 {
                let index = (row * 3 + col) % max(hashData.count, 1)
                let value = hashData.isEmpty ? false : hashData[index] % 2 == 0
                grid[row][col] = value
                grid[row][4 - col] = value // Mirror
            }
        }

        return grid
    }

    var body: some View {
        GeometryReader { geometry in
            let cellSize = geometry.size.width / 5

            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)

                // Pattern
                ForEach(0..<5, id: \.self) { row in
                    ForEach(0..<5, id: \.self) { col in
                        if pattern[row][col] {
                            let xPos: CGFloat = CGFloat(col) * cellSize + cellSize / 2
                            let yPos: CGFloat = CGFloat(row) * cellSize + cellSize / 2
                            Circle()
                                .fill(colors[row % colors.count])
                                .frame(width: cellSize * 0.8, height: cellSize * 0.8)
                                .position(x: xPos, y: yPos)
                        }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Share Sheet

#if os(iOS)
/// UIKit share sheet wrapper for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Preview

// Note: Preview disabled - SettingsViewModel requires AppServices and SettingsRepository
// To preview, use the simulator with the full app.
