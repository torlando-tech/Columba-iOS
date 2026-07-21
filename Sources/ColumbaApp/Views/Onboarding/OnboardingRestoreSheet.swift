#if COLUMBA_MIGRATION_ENABLED
//
//  OnboardingRestoreSheet.swift
//  ColumbaApp
//
//  Sheet presented during onboarding to handle backup restore flow:
//  password entry → preview → import → done.
//

import SwiftUI
import RNSAPI

@available(iOS 17.0, macOS 14.0, *)
struct OnboardingRestoreSheet: View {
    @Bindable var viewModel: MigrationViewModel
    let onComplete: (ImportResult) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isFinishing = false
    @State private var finishErrorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 20) {
                    switch viewModel.state {
                    case .loadingPreview:
                        Spacer()
                        ProgressView()
                            .tint(Theme.accentColor)
                        Text("Reading backup...")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()

                    case .passwordRequired, .wrongPassword:
                        passwordView

                    case .importPreview(let preview, _, _):
                        previewView(preview)

                    case .importing(let progress):
                        Spacer()
                        ProgressView(value: progress)
                            .tint(Theme.secondaryAccent)
                            .padding(.horizontal, 32)
                        Text("Restoring... \(Int(progress * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()

                    case .importComplete(let result):
                        completeView(result)

                    case .error(let message):
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.error)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(Theme.error)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()

                    default:
                        Spacer()
                        ProgressView()
                            .tint(Theme.accentColor)
                        Spacer()
                    }
                }
                .padding(24)
            }
            .navigationTitle("Restore Backup")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.reset()
                        dismiss()
                    }
                    .disabled(isOperationLocked)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isOperationLocked)
        .alert(
            "Unable to Finish Setup",
            isPresented: Binding(
                get: { finishErrorMessage != nil },
                set: { if !$0 { finishErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                finishErrorMessage = nil
            }
        } message: {
            Text(finishErrorMessage ?? "Please try again.")
        }
    }

    private var isOperationLocked: Bool {
        isFinishing || viewModel.isImporting
    }

    // MARK: - Password Entry

    private var passwordView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.secondaryAccent)

            Text("Enter Backup Password")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            if case .wrongPassword = viewModel.state {
                Text("Incorrect password. Please try again.")
                    .font(.caption)
                    .foregroundStyle(Theme.error)
            } else {
                Text("This backup is encrypted. Enter the password used when creating it.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            SecureField("Password", text: $viewModel.importPassword)
                .textContentType(.password)
                .padding(12)
                .background(Theme.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                Task { await viewModel.submitImportPassword() }
            } label: {
                Text("Decrypt")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        viewModel.importPassword.count >= 8
                            ? Theme.secondaryAccent : Theme.backgroundTertiary
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            }
            .disabled(viewModel.importPassword.count < 8)

            Spacer()
        }
    }

    // MARK: - Preview

    private func previewView(_ preview: MigrationPreview) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 40))
                .foregroundStyle(Theme.secondaryAccent)

            Text("Backup Contents")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                if !preview.identityNames.isEmpty {
                    Text("Identities: \(preview.identityNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 16) {
                    statBadge(count: preview.identityCount, label: "Identities")
                    statBadge(count: preview.conversationCount, label: "Chats")
                    statBadge(count: preview.messageCount, label: "Messages")
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                Text("Existing identities and messages will not be duplicated. Conversation details and app settings may be updated from this backup.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            Button {
                Task { await viewModel.confirmImport() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 14, weight: .medium))
                    Text("Restore Data")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            }

            Spacer()
        }
    }

    // MARK: - Complete

    private func completeView(_ result: ImportResult) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.success)

            Text("Restore Complete!")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.success)

            VStack(alignment: .leading, spacing: 4) {
                if result.identitiesImported > 0 {
                    resultRow("Identities", count: result.identitiesImported)
                }
                if result.conversationsImported > 0 {
                    resultRow("Conversations", count: result.conversationsImported)
                }
                if result.messagesImported > 0 {
                    resultRow("Messages", count: result.messagesImported)
                }
                if result.interfacesImported > 0 {
                    resultRow("Interfaces", count: result.interfacesImported)
                }
                if result.settingsImported > 0 {
                    resultRow("Settings", count: result.settingsImported)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()

            Button {
                guard !isFinishing else { return }
                isFinishing = true
                Task {
                    defer { isFinishing = false }
                    do {
                        try await onComplete(result)
                    } catch {
                        finishErrorMessage = error.localizedDescription
                    }
                }
            } label: {
                Group {
                    if isFinishing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Continue")
                            .font(.headline)
                    }
                }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isOperationLocked)
        }
    }

    // MARK: - Helpers

    private func statBadge(count: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func resultRow(_ label: String, count: Int) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 16)
    }
}
#endif
