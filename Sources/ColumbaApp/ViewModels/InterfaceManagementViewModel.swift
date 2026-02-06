//
//  InterfaceManagementViewModel.swift
//  ColumbaApp
//
//  ViewModel for managing Reticulum network interface configurations.
//  Handles interface CRUD operations and connection state tracking.
//

import Foundation
import SwiftUI
import ReticulumSwift

// MARK: - Interface Management ViewModel

/// ViewModel for the interface management screen.
///
/// Manages interface list state, add/edit dialog state, and coordinates
/// with InterfaceRepository for persistence.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class InterfaceManagementViewModel {

    // MARK: - Dependencies

    private let repository: InterfaceRepository
    private let appServices: AppServices

    // MARK: - List State

    /// All configured interfaces
    public var interfaces: [InterfaceEntity] {
        repository.interfaces
    }

    /// Number of enabled interfaces
    public var enabledCount: Int {
        repository.enabledCount
    }

    /// Total number of interfaces
    public var totalCount: Int {
        repository.totalCount
    }

    /// Whether data is loading
    public var isLoading: Bool = false

    /// Current error message (auto-dismissing)
    public var errorMessage: String?

    /// Current success message (auto-dismissing)
    public var successMessage: String?

    /// Whether there are pending changes to apply
    public var hasPendingChanges: Bool = false

    /// Whether changes are being applied
    public var isApplyingChanges: Bool = false

    // MARK: - Dialog State

    /// Whether the add/edit dialog is shown
    public var showConfigSheet: Bool = false

    /// Interface being edited (nil for new interface)
    public var editingInterface: InterfaceEntity?

    /// Whether the type selector is shown
    public var showTypeSelector: Bool = false

    /// Whether the delete confirmation is shown
    public var showDeleteConfirmation: Bool = false

    /// Interface pending deletion
    public var interfaceToDelete: InterfaceEntity?

    // MARK: - Config Form State

    public var configName: String = ""
    public var configType: InterfaceType = .tcpClient
    public var configEnabled: Bool = true
    public var configMode: InterfaceMode = .full

    // TCP Client fields
    public var configTargetHost: String = ""
    public var configTargetPort: String = "4242"
    public var configNetworkName: String = ""
    public var configPassphrase: String = ""
    public var configShowPassphrase: Bool = false

    // TCP Server fields
    public var configListenIp: String = "0.0.0.0"
    public var configListenPort: String = "4242"

    // Auto Interface fields
    public var configAutoGroupId: String = "reticulum"

    // Validation errors
    public var nameError: String?
    public var targetHostError: String?
    public var targetPortError: String?

    // MARK: - Runtime Status

    /// Interface connection status (interface ID -> status)
    public var interfaceStatus: [String: InterfaceStatus] = [:]

    /// Status observation task
    private var statusObserverTask: Task<Void, Never>?

    /// The interface ID currently being monitored for connection
    private var activeInterfaceId: String?

    // MARK: - Computed Properties

    /// Whether we're in edit mode (vs add mode)
    public var isEditing: Bool {
        editingInterface != nil
    }

    /// Whether the form is valid
    public var isFormValid: Bool {
        guard !configName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }

        switch configType {
        case .tcpClient:
            return !configTargetHost.trimmingCharacters(in: .whitespaces).isEmpty
                && isValidPort(configTargetPort)
        case .tcpServer:
            return isValidPort(configListenPort)
        default:
            return true
        }
    }

    // MARK: - Initialization

    public init(repository: InterfaceRepository, appServices: AppServices) {
        self.repository = repository
        self.appServices = appServices
        loadInterfaces()
        startStatusObserver()
    }

    // MARK: - List Operations

    /// Load interfaces from repository.
    public func loadInterfaces() {
        isLoading = true
        repository.loadInterfaces()
        isLoading = false
    }

    /// Toggle interface enabled state.
    public func toggleInterface(_ interface: InterfaceEntity, enabled: Bool) {
        repository.toggleInterface(id: interface.id, enabled: enabled)
        hasPendingChanges = true
    }

    /// Delete an interface.
    public func deleteInterface(_ interface: InterfaceEntity) {
        repository.deleteInterface(id: interface.id)
        hasPendingChanges = true
        showSuccess("Interface deleted")
    }

    /// Confirm and delete the pending interface.
    public func confirmDelete() {
        guard let interface = interfaceToDelete else { return }
        deleteInterface(interface)
        interfaceToDelete = nil
        showDeleteConfirmation = false
    }

    // MARK: - Add/Edit Dialog

    /// Show the type selector for adding a new interface.
    public func showAddInterface() {
        showTypeSelector = true
    }

    /// Select interface type and show config form.
    public func selectInterfaceType(_ type: InterfaceType) {
        showTypeSelector = false
        resetConfigForm()
        configType = type

        // Set default name based on type
        configName = type.displayName

        showConfigSheet = true
    }

    /// Show config form for editing an existing interface.
    public func showEditInterface(_ interface: InterfaceEntity) {
        editingInterface = interface
        populateConfigForm(from: interface)
        showConfigSheet = true
    }

    /// Dismiss the config sheet.
    public func dismissConfigSheet() {
        showConfigSheet = false
        editingInterface = nil
        resetConfigForm()
    }

    /// Save the current config form.
    public func saveInterface() {
        // Validate
        guard validateForm() else { return }

        // Build config
        let config = buildInterfaceConfig()

        if let existing = editingInterface {
            // Update existing
            var updated = existing
            updated.name = configName.trimmingCharacters(in: .whitespaces)
            updated.enabled = configEnabled
            updated.mode = configMode
            updated.config = config

            repository.updateInterface(updated)
            showSuccess("Interface updated")
        } else {
            // Create new
            let newInterface = InterfaceEntity(
                name: configName.trimmingCharacters(in: .whitespaces),
                type: configType,
                enabled: configEnabled,
                mode: configMode,
                config: config
            )

            repository.addInterface(newInterface)
            showSuccess("Interface added")
        }

        hasPendingChanges = true
        dismissConfigSheet()
    }

    // MARK: - Apply Changes

    /// Apply pending interface changes to the running network.
    @MainActor
    public func applyChanges() async {
        guard hasPendingChanges else { return }

        isApplyingChanges = true

        do {
            let enabledInterfaces = repository.getEnabledInterfaces()

            // Handle TCP client interface
            let tcpEntity = enabledInterfaces.first(where: { $0.type == .tcpClient })
            if let tcpInterface = tcpEntity,
               case .tcpClient(let config) = tcpInterface.config {

                let serverAddress = "\(config.targetHost):\(config.targetPort)"
                print("[INTERFACE_VM] Applying changes, connecting to: \(serverAddress)")

                activeInterfaceId = tcpInterface.id
                interfaceStatus[tcpInterface.id] = .connecting

                try await appServices.reconnect(tcpServerAddress: serverAddress)

                showSuccess("Connecting to \(config.targetHost):\(config.targetPort)...")
            } else if tcpEntity == nil {
                // No TCP — shutdown TCP if running
                if appServices.tcpInterface != nil {
                    print("[INTERFACE_VM] No enabled TCP interfaces, shutting down TCP")
                    await appServices.shutdown()
                    activeInterfaceId = nil
                }
            }

            // Handle Auto Discovery interface
            let autoEntity = enabledInterfaces.first(where: { $0.type == .autoInterface })
            if let autoIf = autoEntity,
               case .autoInterface(let config) = autoIf.config {

                let groupId = config.groupId ?? "reticulum"
                print("[INTERFACE_VM] Starting AutoInterface with group: \(groupId)")

                interfaceStatus[autoIf.id] = .connecting
                try await appServices.startAutoInterface(groupId: groupId)
                interfaceStatus[autoIf.id] = .connected
                showSuccess("Auto Discovery started (group: \(groupId))")
            } else {
                // No enabled auto interface — stop if running
                await appServices.stopAutoInterface()
            }

            hasPendingChanges = false

            if tcpEntity == nil && autoEntity == nil {
                showSuccess("Disconnected")
            }
        } catch {
            print("[INTERFACE_VM] Apply failed: \(error)")
            if let id = activeInterfaceId {
                interfaceStatus[id] = .error
            }
            showError("Connection failed: \(error.localizedDescription)")
        }

        isApplyingChanges = false
    }

    // MARK: - Status Observation

    /// Start polling AppServices connection state to update interface status.
    ///
    /// On the first iteration, this also performs initial sync — detecting
    /// interfaces that are already running (from app startup) and reflecting
    /// their true state in the UI.
    private func startStatusObserver() {
        statusObserverTask?.cancel()
        statusObserverTask = Task { @MainActor [weak self] in
            // Initial sync: detect already-running TCP interface
            if let self = self {
                let enabledInterfaces = self.repository.getEnabledInterfaces()
                if let tcpEntity = enabledInterfaces.first(where: { $0.type == .tcpClient }),
                   self.appServices.tcpInterface != nil {
                    self.activeInterfaceId = tcpEntity.id
                }
            }

            while !Task.isCancelled {
                guard let self = self else { break }

                // Track TCP interface status
                if let interfaceId = self.activeInterfaceId {
                    if self.appServices.isConnected {
                        if self.interfaceStatus[interfaceId] != .connected {
                            self.interfaceStatus[interfaceId] = .connected
                            self.errorMessage = nil
                        }
                    } else if self.appServices.isReconnecting {
                        self.interfaceStatus[interfaceId] = .reconnecting
                        if let error = self.appServices.connectionError,
                           self.errorMessage != error {
                            self.showError(error)
                        }
                    } else if self.appServices.connectionError != nil {
                        self.interfaceStatus[interfaceId] = .error
                        if let error = self.appServices.connectionError,
                           self.errorMessage != error {
                            self.showError(error)
                        }
                    }
                }

                // Track Auto interface status
                let enabledInterfaces = self.repository.getEnabledInterfaces()
                if let autoEntity = enabledInterfaces.first(where: { $0.type == .autoInterface }) {
                    if let auto = self.appServices.autoInterface {
                        let autoState = await auto.state
                        let peerCount = await auto.peerCount
                        switch autoState {
                        case .connected:
                            self.interfaceStatus[autoEntity.id] = .connected
                        case .connecting:
                            self.interfaceStatus[autoEntity.id] = .connecting
                        default:
                            if peerCount > 0 {
                                self.interfaceStatus[autoEntity.id] = .connected
                            } else {
                                self.interfaceStatus[autoEntity.id] = .disconnected
                            }
                        }
                    } else {
                        self.interfaceStatus[autoEntity.id] = .disconnected
                    }
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }
        }
    }

    // MARK: - Form Helpers

    private func resetConfigForm() {
        configName = ""
        configType = .tcpClient
        configEnabled = true
        configMode = .full
        configTargetHost = ""
        configTargetPort = "4242"
        configNetworkName = ""
        configPassphrase = ""
        configShowPassphrase = false
        configListenIp = "0.0.0.0"
        configListenPort = "4242"
        configAutoGroupId = "reticulum"
        nameError = nil
        targetHostError = nil
        targetPortError = nil
    }

    private func populateConfigForm(from interface: InterfaceEntity) {
        configName = interface.name
        configType = interface.type
        configEnabled = interface.enabled
        configMode = interface.mode

        switch interface.config {
        case .tcpClient(let config):
            configTargetHost = config.targetHost
            configTargetPort = String(config.targetPort)
            configNetworkName = config.networkName ?? ""
            configPassphrase = config.passphrase ?? ""

        case .tcpServer(let config):
            configListenIp = config.listenIp
            configListenPort = String(config.listenPort)

        case .autoInterface(let config):
            configAutoGroupId = config.groupId ?? "reticulum"
        }
    }

    private func buildInterfaceConfig() -> InterfaceTypeConfig {
        switch configType {
        case .tcpClient:
            return .tcpClient(TCPClientConfig(
                targetHost: configTargetHost.trimmingCharacters(in: .whitespaces),
                targetPort: UInt16(configTargetPort) ?? 4242,
                networkName: configNetworkName.isEmpty ? nil : configNetworkName,
                passphrase: configPassphrase.isEmpty ? nil : configPassphrase
            ))

        case .tcpServer:
            return .tcpServer(TCPServerConfig(
                listenIp: configListenIp.trimmingCharacters(in: .whitespaces),
                listenPort: UInt16(configListenPort) ?? 4242
            ))

        case .autoInterface:
            let groupId = configAutoGroupId.trimmingCharacters(in: .whitespaces)
            return .autoInterface(AutoInterfaceConfig(
                groupId: groupId.isEmpty ? nil : groupId
            ))

        default:
            // Default to TCP client for unsupported types
            return .tcpClient(TCPClientConfig(
                targetHost: configTargetHost,
                targetPort: 4242
            ))
        }
    }

    private func validateForm() -> Bool {
        var valid = true

        // Name validation
        let name = configName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            nameError = "Name is required"
            valid = false
        } else if name.count > 50 {
            nameError = "Name must be 50 characters or less"
            valid = false
        } else {
            nameError = nil
        }

        // Type-specific validation
        switch configType {
        case .tcpClient:
            let host = configTargetHost.trimmingCharacters(in: .whitespaces)
            if host.isEmpty {
                targetHostError = "Host is required"
                valid = false
            } else {
                targetHostError = nil
            }

            if !isValidPort(configTargetPort) {
                targetPortError = "Invalid port (1-65535)"
                valid = false
            } else {
                targetPortError = nil
            }

        default:
            targetHostError = nil
            targetPortError = nil
        }

        return valid
    }

    private func isValidPort(_ portString: String) -> Bool {
        guard let port = UInt16(portString), port > 0 else {
            return false
        }
        return true
    }

    // MARK: - Messages

    private func showError(_ message: String) {
        errorMessage = message
        // Auto-dismiss after 5 seconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.errorMessage == message {
                self.errorMessage = nil
            }
        }
    }

    private func showSuccess(_ message: String) {
        successMessage = message
        // Auto-dismiss after 3 seconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.successMessage == message {
                self.successMessage = nil
            }
        }
    }

    // MARK: - Status Updates

    /// Update interface status from AppServices.
    public func updateInterfaceStatus(id: String, status: InterfaceStatus) {
        interfaceStatus[id] = status
    }

    /// Get status for an interface.
    public func getStatus(for interface: InterfaceEntity) -> InterfaceStatus {
        interfaceStatus[interface.id] ?? .disconnected
    }
}
