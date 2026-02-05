//
//  InterfaceManagementViewModel.swift
//  ColumbaApp
//
//  ViewModel for managing Reticulum network interface configurations.
//  Handles interface CRUD operations and connection state tracking.
//

import Foundation
import SwiftUI

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
    private let settingsRepository: SettingsRepository

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

    public init(repository: InterfaceRepository, appServices: AppServices, settingsRepository: SettingsRepository) {
        self.repository = repository
        self.appServices = appServices
        self.settingsRepository = settingsRepository
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
            // Get enabled TCP client interfaces
            let enabledInterfaces = repository.getEnabledInterfaces()

            // For now, we only support a single TCP interface
            // Find the first enabled TCP client
            if let tcpInterface = enabledInterfaces.first(where: { $0.type == .tcpClient }),
               case .tcpClient(let config) = tcpInterface.config {

                // Build relay address
                let relayAddress = "\(config.targetHost):\(config.targetPort)"
                print("[INTERFACE_VM] Applying changes, connecting to: \(relayAddress)")

                // Mark as connecting
                activeInterfaceId = tcpInterface.id
                interfaceStatus[tcpInterface.id] = .connecting

                // Persist relay address for next app launch
                await settingsRepository.setRelayAddress(relayAddress)

                // Reconnect AppServices with new relay address
                try await appServices.reconnect(relayAddress: relayAddress)

                hasPendingChanges = false
                showSuccess("Connecting to \(config.targetHost):\(config.targetPort)...")

            } else {
                // No enabled TCP interfaces - disconnect
                print("[INTERFACE_VM] No enabled TCP interfaces, shutting down")
                await appServices.shutdown()
                activeInterfaceId = nil
                hasPendingChanges = false
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
    private func startStatusObserver() {
        statusObserverTask?.cancel()
        statusObserverTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                if let interfaceId = self.activeInterfaceId {
                    if self.appServices.isConnected {
                        if self.interfaceStatus[interfaceId] != .connected {
                            self.interfaceStatus[interfaceId] = .connected
                            self.errorMessage = nil
                        }
                    } else if self.appServices.isReconnecting {
                        self.interfaceStatus[interfaceId] = .reconnecting
                        // Show the connection error if available
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

        case .autoInterface:
            break
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
