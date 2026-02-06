//
//  IdentityManagerView.swift
//  ColumbaApp
//
//  Manage multiple identities: list, create, switch, rename, delete.
//  Pushed from "Manage Identities" in SettingsView.
//

import SwiftUI

/// View for managing multiple local identities.
///
/// Displays a list of identities with the active one highlighted.
/// Supports create, switch, rename, and delete via context menus and dialogs.
@available(iOS 17.0, macOS 14.0, *)
struct IdentityManagerView: View {
    // MARK: - Dependencies

    let identityManager: IdentityManager
    let appServices: AppServices
    let settingsRepository: SettingsRepository
    /// Called after an identity switch to trigger RootView re-initialization.
    var onIdentitySwitch: (() -> Void)?

    // MARK: - State

    @State private var identities: [LocalIdentity] = []
    @State private var isLoading = true

    // Create dialog
    @State private var showCreateAlert = false
    @State private var newIdentityName = ""

    // Switch dialog
    @State private var showSwitchAlert = false
    @State private var switchTarget: LocalIdentity?

    // Rename dialog
    @State private var showRenameAlert = false
    @State private var renameTarget: LocalIdentity?
    @State private var renameText = ""

    // Delete dialog
    @State private var showDeleteAlert = false
    @State private var deleteTarget: LocalIdentity?

    // Error
    @State private var errorMessage: String?

    // Switch in progress
    @State private var isSwitching = false

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if identities.isEmpty {
                    emptyState
                } else {
                    ForEach(identities) { identity in
                        identityCard(identity)
                    }
                }

                createButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.backgroundPrimary)
        .navigationTitle("Manage Identities")
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
        #endif
        .task {
            await loadIdentities()
        }
        .alert("Create New Identity", isPresented: $showCreateAlert) {
            TextField("e.g., Work, Personal", text: $newIdentityName)
            Button("Create") { Task { await createIdentity() } }
            Button("Cancel", role: .cancel) { newIdentityName = "" }
        } message: {
            Text("Enter a display name for this identity.")
        }
        .alert("Switch Identity", isPresented: $showSwitchAlert) {
            Button("Switch") { Task { await performSwitch() } }
            Button("Cancel", role: .cancel) { switchTarget = nil }
        } message: {
            if let target = switchTarget {
                Text("Switching to '\(target.displayName)' will restart the network connection. You will only see this identity's conversations.")
            }
        }
        .alert("Rename Identity", isPresented: $showRenameAlert) {
            TextField("Display name", text: $renameText)
            Button("Rename") { Task { await performRename() } }
            Button("Cancel", role: .cancel) { renameTarget = nil; renameText = "" }
        } message: {
            Text("Enter a new display name.")
        }
        .alert("Delete Identity", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            if let target = deleteTarget {
                Text("This permanently deletes '\(target.displayName)' and ALL its conversations and messages. This cannot be undone.")
            }
        }
        .overlay {
            if isSwitching {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(Theme.accentColor)
                            .scaleEffect(1.5)
                        Text("Switching identity...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    // MARK: - Identity Card

    private func identityCard(_ identity: LocalIdentity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(identity.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        if identity.isActive {
                            Text("Active")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Theme.accentColor)
                                .clipShape(Capsule())
                        }
                    }

                    Text(truncatedHash(identity.identityHash))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                if !identity.isActive {
                    Menu {
                        Button {
                            switchTarget = identity
                            showSwitchAlert = true
                        } label: {
                            Label("Switch To", systemImage: "arrow.right.arrow.left")
                        }

                        Button {
                            renameTarget = identity
                            renameText = identity.displayName
                            showRenameAlert = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            deleteTarget = identity
                            showDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    // Active identity can only be renamed
                    Button {
                        renameTarget = identity
                        renameText = identity.displayName
                        showRenameAlert = true
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            // Last used
            HStack(spacing: 4) {
                Text("Last used:")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(Date(timeIntervalSince1970: identity.lastUsedAt), style: .relative)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text("ago")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.error)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                .fill(identity.isActive ? Theme.accentColor.opacity(0.1) : Theme.backgroundSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                        .stroke(identity.isActive ? Theme.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)

            Text("No Identities")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Create your first identity to get started.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Create Button

    private var createButton: some View {
        Button {
            newIdentityName = ""
            showCreateAlert = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                Text("Create New Identity")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        }
    }

    // MARK: - Actions

    private func loadIdentities() async {
        identities = await identityManager.getAllIdentities()
        isLoading = false
    }

    private func createIdentity() async {
        let name = newIdentityName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        do {
            _ = try await identityManager.createIdentity(displayName: name)
            await loadIdentities()
        } catch {
            errorMessage = error.localizedDescription
        }

        newIdentityName = ""
    }

    private func performSwitch() async {
        guard let target = switchTarget else { return }
        isSwitching = true
        errorMessage = nil

        do {
            let (localId, identity) = try await identityManager.switchToIdentity(target.identityHash)

            // Update display name in settings repo for announce compatibility
            await settingsRepository.setDisplayName(localId.displayName)

            // Get server address
            let interfaceRepo = InterfaceRepository()
            let serverAddress: String
            if let tcpEntity = interfaceRepo.getEnabledInterfaces().first(where: { $0.type == .tcpClient }),
               case .tcpClient(let config) = tcpEntity.config {
                serverAddress = "\(config.targetHost):\(config.targetPort)"
            } else {
                serverAddress = ""
            }

            try await appServices.switchIdentity(
                to: identity,
                identityHash: localId.identityHash,
                tcpServerAddress: serverAddress
            )

            await loadIdentities()
            isSwitching = false

            // Notify parent to re-initialize dependent services
            onIdentitySwitch?()
        } catch {
            isSwitching = false
            errorMessage = error.localizedDescription
        }

        switchTarget = nil
    }

    private func performRename() async {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        await identityManager.renameIdentity(target.identityHash, newName: name)

        // If renaming active identity, also update settings repo
        if target.isActive {
            await settingsRepository.setDisplayName(name)
        }

        await loadIdentities()
        renameTarget = nil
        renameText = ""
    }

    private func performDelete() async {
        guard let target = deleteTarget else { return }

        do {
            try await identityManager.deleteIdentity(target.identityHash)
            await loadIdentities()
        } catch {
            errorMessage = error.localizedDescription
        }

        deleteTarget = nil
    }

    // MARK: - Helpers

    private func truncatedHash(_ hash: String) -> String {
        guard hash.count > 12 else { return hash }
        let start = hash.prefix(6)
        let end = hash.suffix(6)
        return "\(start)...\(end)"
    }
}
