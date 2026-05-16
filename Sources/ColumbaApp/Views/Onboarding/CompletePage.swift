#if COLUMBA_ONBOARDING_ENABLED
//
//  CompletePage.swift
//  ColumbaApp
//
//  Onboarding page 4: Summary and completion.
//

import SwiftUI
import RNSAPI
import CoreImage.CIFilterBuiltins

@available(iOS 17.0, macOS 14.0, *)
struct CompletePage: View {
    let displayName: String
    let interfaceNames: String
    let notificationsGranted: Bool
    let isSaving: Bool
    let selectedRNode: Bool
    let identityManager: IdentityManager
    let qrCodeString: String
    let onPrepare: () async -> Void
    let onFinish: () -> Void

    @State private var showQRSheet = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Theme.success)
                .padding(.bottom, 24)

            Text("You're all set!")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 24)

            // Summary card
            VStack(alignment: .leading, spacing: 14) {
                summaryRow(icon: "person.fill", label: "Identity", value: displayName)
                Divider().overlay(Theme.divider)
                summaryRow(icon: "antenna.radiowaves.left.and.right", label: "Networks", value: interfaceNames)
                Divider().overlay(Theme.divider)
                HStack(spacing: 12) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.accentColor)
                        .frame(width: 24)

                    Text("Notifications")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    Spacer()

                    if notificationsGranted {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.caption2.bold())
                            Text("Enabled")
                        }
                        .font(.subheadline)
                        .foregroundStyle(Theme.success)
                    } else {
                        Text("Disabled")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textDisabled)
                    }
                }
            }
            .padding(16)
            .background(Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.divider, lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 24)

            // QR Code button
            Button { showQRSheet = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode")
                    Text("Show QR Code")
                }
                .font(.subheadline.bold())
                .foregroundStyle(Theme.accentColor)
            }
            .padding(.bottom, 8)

            Spacer()

            // Finish buttons
            VStack(spacing: 12) {
                Button(action: onFinish) {
                    Group {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(selectedRNode ? "Configure LoRa Radio" : "Start Messaging")
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isSaving)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showQRSheet) {
            qrCodeSheet
        }
        .task {
            await onPrepare()
        }
    }

    // MARK: - Summary Row

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accentColor)
                .frame(width: 24)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - QR Code Sheet

    private var qrCodeSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Text("Share Your Identity")
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                if qrCodeString.isEmpty {
                    ProgressView()
                        .tint(Theme.accentColor)
                    Text("Generating identity...")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    if let cgImage = Self.generateQRCode(from: qrCodeString) {
                        Image(decorative: cgImage, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Text("Scan this code to add you as a contact")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Theme.backgroundPrimary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showQRSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - QR Code Generation

    private static func generateQRCode(from string: String) -> CGImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)

        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
#endif
