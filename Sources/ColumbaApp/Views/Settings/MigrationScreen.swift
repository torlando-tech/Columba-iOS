#if COLUMBA_MIGRATION_ENABLED
//
//  MigrationScreen.swift
//  ColumbaApp
//
//  Full-screen settings view for data export/import.
//  Matches Android Columba's MigrationScreen layout with glass cards.
//

import SwiftUI
import RNSAPI
import UniformTypeIdentifiers

@available(iOS 17.0, macOS 14.0, *)
struct MigrationScreen: View {
    @State private var viewModel: MigrationViewModel
    @State private var showFileImporter = false
    @State private var showFileExporter = false
    @State private var exportDocument: ColumbaBackupDocument?
    @State private var exportFileName = "columba_backup.columba"

    init(
        identityManager: IdentityManager,
        settingsRepository: SettingsRepository,
        appServices: AppServices
    ) {
        _viewModel = State(initialValue: MigrationViewModel(
            identityManager: identityManager,
            settingsRepository: settingsRepository,
            appServices: appServices
        ))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                exportSection
                importSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.backgroundPrimary)
        .navigationTitle("Data Migration")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .task {
            await viewModel.loadExportPreview()
        }
        .sheet(isPresented: $viewModel.showExportPasswordSheet) {
            exportPasswordSheet
        }
        .sheet(isPresented: $viewModel.showImportPasswordSheet) {
            importPasswordSheet
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [columbaUTType, .json],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: columbaUTType,
            defaultFilename: exportFileName
        ) { result in
            exportDocument = nil
            viewModel.handleExportSaveResult(result)
        }
    }

    // MARK: - Export Section

    private var exportSection: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.accentColor.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Export Data")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Create an encrypted backup of all your data")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()
            }
            .padding(16)

            // Preview stats
            if let preview = viewModel.exportPreview {
                VStack(spacing: 8) {
                    Divider()
                        .overlay(Theme.divider)

                    HStack(spacing: 16) {
                        statBadge(count: preview.identityCount, label: "Identities")
                        statBadge(count: preview.conversationCount, label: "Chats")
                        statBadge(count: preview.messageCount, label: "Messages")
                        statBadge(count: preview.interfaceCount, label: "Interfaces")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            // Export action / progress
            VStack(spacing: 12) {
                switch viewModel.state {
                case .exporting(let progress):
                    ProgressView(value: progress)
                        .tint(Theme.accentColor)
                        .padding(.horizontal, 16)
                    Text("Exporting... \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                default:
                    Button {
                        viewModel.showExportPasswordSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 14, weight: .medium))
                            Text("Export All Data")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
        .glassCard()
    }

    // MARK: - Import Section

    private var importSection: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.secondaryAccent.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.secondaryAccent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Data")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Restore from a .columba backup file")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()
            }
            .padding(16)

            VStack(spacing: 12) {
                switch viewModel.state {
                case .loadingPreview:
                    ProgressView()
                        .tint(Theme.accentColor)
                    Text("Reading backup...")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                case .importPreview(let preview, _, _):
                    importPreviewCard(preview)

                case .importing(let progress):
                    ProgressView(value: progress)
                        .tint(Theme.secondaryAccent)
                        .padding(.horizontal, 16)
                    Text("Importing... \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                case .importComplete(let result):
                    importResultCard(result)

                case .error(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.error)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Theme.error)
                    }
                    .padding(.horizontal, 16)

                    selectFileButton

                default:
                    selectFileButton
                }
            }
            .padding(.bottom, 16)
        }
        .glassCard()
    }

    // MARK: - Components

    private var selectFileButton: some View {
        Button {
            showFileImporter = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 14, weight: .medium))
                Text("Select Backup File")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.backgroundTertiary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        }
        .padding(.horizontal, 16)
    }

    private func importPreviewCard(_ preview: MigrationPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .overlay(Theme.divider)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Version:")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text("v\(preview.version)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer()

                    Text("Platform:")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(preview.platform)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                }

                HStack {
                    Text("Exported:")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(preview.exportedAt, style: .date)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                }

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
            .padding(.horizontal, 16)

            // Warning
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                Text("Existing data will be preserved. Only new items will be added.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)

            // Import button
            Button {
                Task { await viewModel.confirmImport() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 14, weight: .medium))
                    Text("Import Data")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.secondaryAccent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            }
            .padding(.horizontal, 16)
        }
    }

    private func importResultCard(_ result: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                Text("Import complete!")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.success)
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                resultRow("Identities imported", count: result.identitiesImported)
                if result.identitiesSkipped > 0 {
                    resultRow("Identities skipped (existing)", count: result.identitiesSkipped)
                }
                resultRow("Conversations imported", count: result.conversationsImported)
                resultRow("Messages imported", count: result.messagesImported)
                if result.messagesSkipped > 0 {
                    resultRow("Messages skipped (duplicates)", count: result.messagesSkipped)
                }
                resultRow("Interfaces imported", count: result.interfacesImported)
                resultRow("Settings restored", count: result.settingsImported)
            }
            .padding(.horizontal, 16)

            if result.identitiesImported > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    Text("Restart the app to use imported identities.")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
                .padding(.horizontal, 16)
            }

            Button {
                viewModel.reset()
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            }
            .padding(.horizontal, 16)
        }
    }

    private func resultRow(_ label: String, count: Int) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
    }

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

    // MARK: - Password Sheets

    private var exportPasswordSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accentColor)

                Text("Set Backup Password")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Choose a strong password to encrypt your backup. You'll need this password to restore your data.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    SecureField("Password (8+ characters)", text: $viewModel.exportPassword)
                        .textContentType(.newPassword)
                        .padding(12)
                        .background(Theme.backgroundTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    SecureField("Confirm Password", text: $viewModel.exportPasswordConfirm)
                        .textContentType(.newPassword)
                        .padding(12)
                        .background(Theme.backgroundTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if !viewModel.exportPassword.isEmpty && viewModel.exportPassword.count < 8 {
                        Text("Password must be at least 8 characters")
                            .font(.caption2)
                            .foregroundStyle(Theme.error)
                    }

                    if !viewModel.exportPasswordConfirm.isEmpty &&
                        viewModel.exportPassword != viewModel.exportPasswordConfirm {
                        Text("Passwords do not match")
                            .font(.caption2)
                            .foregroundStyle(Theme.error)
                    }
                }

                Button {
                    Task { await beginExport() }
                } label: {
                    Text("Export")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(viewModel.isExportPasswordValid ? Theme.accentColor : Theme.backgroundTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
                .disabled(!viewModel.isExportPasswordValid)

                Spacer()
            }
            .padding(24)
            .background(Theme.backgroundPrimary)
            .navigationTitle("Encrypt Backup")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showExportPasswordSheet = false
                        viewModel.exportPassword = ""
                        viewModel.exportPasswordConfirm = ""
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var importPasswordSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 48))
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                viewModel.state == .wrongPassword(fileData: Data())
                                    ? Theme.error : Color.clear,
                                lineWidth: 1
                            )
                    )

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
            .padding(24)
            .background(Theme.backgroundPrimary)
            .navigationTitle("Decrypt Backup")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showImportPasswordSheet = false
                        viewModel.importPassword = ""
                        viewModel.reset()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - File Handling

    private func beginExport() async {
        guard let url = await viewModel.startExport() else { return }

        do {
            let data = try Data(contentsOf: url)
            exportDocument = ColumbaBackupDocument(data: data)
            exportFileName = url.lastPathComponent
            showFileExporter = true
        } catch {
            viewModel.state = .error(message: "Failed to prepare backup: \(error.localizedDescription)")
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                Task { await viewModel.handleImportFile(data: data) }
            } catch {
                viewModel.state = .error(message: "Failed to read file: \(error.localizedDescription)")
            }

        case .failure(let error):
            viewModel.state = .error(message: "File selection failed: \(error.localizedDescription)")
        }
    }

    /// UTType for .columba files.
    private var columbaUTType: UTType {
        UTType(filenameExtension: "columba") ?? .data
    }
}

// MARK: - FileDocument wrapper for .fileExporter

@available(iOS 17.0, macOS 14.0, *)
struct ColumbaBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "columba") ?? .data] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let fileData = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = fileData
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
