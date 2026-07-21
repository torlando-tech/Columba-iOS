#if COLUMBA_MIGRATION_ENABLED
//
//  MigrationViewModel.swift
//  ColumbaApp
//
//  Observable state management for the data migration (export/import) screen.
//  Handles password validation, progress tracking, and state transitions.
//

import Foundation
import RNSAPI
import SwiftUI
import os.log

/// View model for the data migration screen.
@available(macOS 14.0, iOS 17.0, *)
@Observable @MainActor
final class MigrationViewModel {
    // MARK: - State

    enum MigrationState: Equatable {
        case idle
        case loadingPreview
        case exporting(progress: Float)
        case exportComplete(url: URL)
        case passwordRequired(fileData: Data)
        case wrongPassword(fileData: Data)
        case importPreview(preview: MigrationPreview, fileData: Data, password: String?)
        case importing(progress: Float)
        case importComplete(result: ImportResult)
        case error(message: String)

        static func == (lhs: MigrationState, rhs: MigrationState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.loadingPreview, .loadingPreview): return true
            case (.exporting(let a), .exporting(let b)): return a == b
            case (.exportComplete(let a), .exportComplete(let b)): return a == b
            case (.passwordRequired, .passwordRequired): return true
            case (.wrongPassword, .wrongPassword): return true
            case (.importPreview, .importPreview): return true
            case (.importing(let a), .importing(let b)): return a == b
            case (.importComplete, .importComplete): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    var state: MigrationState = .idle
    private(set) var isImporting = false
    private var activeImportGeneration: UUID?
    private var activeExportGeneration: UUID?

    /// Export preview stats (loaded on appear).
    var exportPreview: ExportPreview?

    /// Export password fields.
    var exportPassword = ""
    var exportPasswordConfirm = ""
    var showExportPasswordSheet = false

    /// Import password field.
    var importPassword = ""
    var showImportPasswordSheet = false

    // MARK: - Dependencies

    private let exporter: MigrationExporter
    private let importer: MigrationImporter
    private let logger = Logger(subsystem: "network.columba.Columba", category: "MigrationViewModel")

    // MARK: - Cached data for import flow

    private var pendingImportData: Data?
    private var pendingImportPassword: String?

    // MARK: - Init

    init(identityManager: IdentityManager, settingsRepository: SettingsRepository) {
        self.exporter = MigrationExporter(
            identityManager: identityManager,
            settingsRepository: settingsRepository
        )
        self.importer = MigrationImporter(
            identityManager: identityManager,
            settingsRepository: settingsRepository
        )
    }

    // MARK: - Export

    /// Load export preview stats (identity/message/conversation counts).
    func loadExportPreview() async {
        do {
            exportPreview = try await exporter.getExportPreview()
        } catch {
            logger.warning("Failed to load export preview: \(error)")
        }
    }

    /// Validate export password fields.
    var isExportPasswordValid: Bool {
        exportPassword.count >= 8 && exportPassword == exportPasswordConfirm
    }

    /// Start the export process.
    func startExport() async {
        guard isExportPasswordValid, activeExportGeneration == nil else { return }
        let generation = UUID()
        activeExportGeneration = generation
        defer {
            if activeExportGeneration == generation {
                activeExportGeneration = nil
            }
        }
        let password = exportPassword
        showExportPasswordSheet = false
        state = .exporting(progress: 0)

        do {
            let url = try await exporter.exportData(password: password) { [weak self] progress in
                Task { @MainActor in
                    guard self?.activeExportGeneration == generation else { return }
                    self?.state = .exporting(progress: progress)
                }
            }
            activeExportGeneration = nil
            state = .exportComplete(url: url)
            logger.info("Export complete: \(url.lastPathComponent)")
        } catch {
            activeExportGeneration = nil
            state = .error(message: "Export failed: \(error.localizedDescription)")
            logger.error("Export failed: \(error)")
        }

        exportPassword = ""
        exportPasswordConfirm = ""
    }

    // MARK: - Import

    /// Handle a selected backup file — detect encryption, request password or preview.
    func handleImportFile(data: Data) async {
        if importer.isEncrypted(data) {
            pendingImportData = data
            state = .passwordRequired(fileData: data)
            showImportPasswordSheet = true
        } else {
            // Unencrypted (raw JSON) — preview directly
            await previewImport(data: data, password: nil)
        }
    }

    /// Attempt to decrypt and preview with password.
    func submitImportPassword() async {
        guard let data = pendingImportData else { return }
        let password = importPassword
        showImportPasswordSheet = false
        await previewImport(data: data, password: password)
    }

    /// Preview backup contents.
    private func previewImport(data: Data, password: String?) async {
        state = .loadingPreview

        do {
            let preview = try await importer.previewMigration(data: data, password: password)
            pendingImportData = data
            pendingImportPassword = password
            state = .importPreview(preview: preview, fileData: data, password: password)
        } catch let error as MigrationCryptoError {
            switch error {
            case .wrongPassword:
                state = .wrongPassword(fileData: data)
                showImportPasswordSheet = true
                importPassword = ""
            case .passwordRequired:
                state = .passwordRequired(fileData: data)
                showImportPasswordSheet = true
            default:
                state = .error(message: error.localizedDescription)
            }
        } catch {
            state = .error(message: "Failed to read backup: \(error.localizedDescription)")
        }
    }

    /// Confirm and execute the import.
    func confirmImport() async {
        guard let data = pendingImportData else { return }
        guard !isImporting else { return }
        isImporting = true
        let generation = UUID()
        activeImportGeneration = generation
        defer {
            if activeImportGeneration == generation {
                activeImportGeneration = nil
            }
            isImporting = false
        }
        let password = pendingImportPassword
        state = .importing(progress: 0)

        do {
            let result = try await importer.importData(data: data, password: password) { [weak self] progress in
                Task { @MainActor in
                    guard self?.activeImportGeneration == generation else { return }
                    self?.state = .importing(progress: progress)
                }
            }
            // Invalidate queued progress jobs before publishing terminal state.
            activeImportGeneration = nil
            state = .importComplete(result: result)
            logger.info("Import complete")
        } catch {
            activeImportGeneration = nil
            state = .error(message: "Import failed: \(error.localizedDescription)")
            logger.error("Import failed: \(error)")
        }

        pendingImportData = nil
        pendingImportPassword = nil
        importPassword = ""
    }

    /// Reset state back to idle.
    func reset() {
        activeImportGeneration = nil
        activeExportGeneration = nil
        state = .idle
        pendingImportData = nil
        pendingImportPassword = nil
        importPassword = ""
        exportPassword = ""
        exportPasswordConfirm = ""
    }
}

// MARK: - MigrationPreview Equatable

extension MigrationPreview: Equatable {
    static func == (lhs: MigrationPreview, rhs: MigrationPreview) -> Bool {
        lhs.version == rhs.version && lhs.exportedAt == rhs.exportedAt
    }
}

// MARK: - ImportResult Equatable

extension ImportResult: Equatable {
    static func == (lhs: ImportResult, rhs: ImportResult) -> Bool {
        lhs.messagesImported == rhs.messagesImported &&
        lhs.identitiesImported == rhs.identitiesImported
    }
}
#endif
