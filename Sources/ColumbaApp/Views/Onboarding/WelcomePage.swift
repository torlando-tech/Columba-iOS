#if COLUMBA_ONBOARDING_ENABLED
//
//  WelcomePage.swift
//  ColumbaApp
//
//  Onboarding page 0: Welcome screen explaining Columba's privacy model.
//

import SwiftUI
import RNSAPI
import UniformTypeIdentifiers

@available(iOS 17.0, macOS 14.0, *)
struct WelcomePage: View {
    let onContinue: () -> Void
    /// Optional — only wired (and the "Restore from backup" affordance only shown)
    /// when the migration/restore path is compiled in (`COLUMBA_MIGRATION_ENABLED`).
    var onRestoreFile: ((Data) -> Void)? = nil

    @State private var showingFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon
            ZStack {
                Circle()
                    .fill(Theme.accentColor.opacity(0.2))
                    .frame(width: 100, height: 100)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accentColor)
            }
            .padding(.bottom, 24)

            Text("Welcome to Columba")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            Text("Private messaging without a central account")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 24)

            // Privacy bullet points
            VStack(alignment: .leading, spacing: 16) {
                privacyRow("No phone number or email", icon: "xmark.circle")
                privacyRow("No central account or sign-up", icon: "xmark.circle")
                privacyRow("Internet, local, Bluetooth, and radio connections", icon: "antenna.radiowaves.left.and.right")
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)

            Text("Columba creates a private cryptographic identity on your device. You control it — and can protect it with an encrypted backup.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            // Buttons
            VStack(spacing: 12) {
                Button(action: onContinue) {
                    Text("Get Started")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.accentGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                #if COLUMBA_MIGRATION_ENABLED
                if onRestoreFile != nil {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Text("Restore from backup")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                #endif
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        #if COLUMBA_MIGRATION_ENABLED
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "columba") ?? .data,
                .json
            ],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    onRestoreFile?(data)
                }
            }
        }
        #endif
    }

    private func privacyRow(_ text: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.accentColor)
                .frame(width: 24)

            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}
#endif
