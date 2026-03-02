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

    /// Whether the RNode wizard is shown (uses fullScreenCover to survive BLE pairing dialog)
    public var showRNodeWizard: Bool = false

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

    // RNode fields
    public var configDeviceName: String = ""
    public var configFrequency: String = "915000000"
    public var configBandwidth: String = "125000"
    public var configTxPower: String = "17"
    public var configSpreadingFactor: String = "7"
    public var configCodingRate: String = "5"

    // Validation errors
    public var nameError: String?
    public var targetHostError: String?
    public var targetPortError: String?
    public var deviceNameError: String?
    public var frequencyError: String?

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
        case .rnode:
            return !configDeviceName.trimmingCharacters(in: .whitespaces).isEmpty
                && UInt32(configFrequency) != nil
                && UInt32(configBandwidth) != nil
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

    /// Toggle interface enabled state and immediately apply.
    public func toggleInterface(_ interface: InterfaceEntity, enabled: Bool) {
        repository.toggleInterface(id: interface.id, enabled: enabled)
        hasPendingChanges = true
        Task { @MainActor in
            await applyChanges()
        }
    }

    /// Delete an interface and stop it if running.
    public func deleteInterface(_ interface: InterfaceEntity) {
        repository.deleteInterface(id: interface.id)
        hasPendingChanges = true
        showSuccess("Interface deleted")
        Task { @MainActor in
            await applyChanges()
        }
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

        if type == .rnode {
            showRNodeWizard = true
        } else {
            showConfigSheet = true
        }
    }

    /// Show config form for editing an existing interface.
    public func showEditInterface(_ interface: InterfaceEntity) {
        editingInterface = interface
        populateConfigForm(from: interface)
        if interface.type == .rnode {
            showRNodeWizard = true
        } else {
            showConfigSheet = true
        }
    }

    /// Dismiss the config sheet.
    public func dismissConfigSheet() {
        showConfigSheet = false
        showRNodeWizard = false
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

        // Auto-apply so the interface starts/stops immediately
        Task { @MainActor in
            await applyChanges()
        }
    }

    // MARK: - Apply Changes

    /// Apply pending interface changes to the running network.
    ///
    /// Only starts/stops the interfaces that actually changed, leaving
    /// other running interfaces untouched.
    @MainActor
    public func applyChanges() async {
        guard hasPendingChanges else { return }

        isApplyingChanges = true

        let enabledInterfaces = repository.getEnabledInterfaces()

        // --- TCP ---
        let tcpEntity = enabledInterfaces.first(where: { $0.type == .tcpClient })
        if let tcpIf = tcpEntity,
           case .tcpClient(let config) = tcpIf.config {
            let serverAddress = "\(config.targetHost):\(config.targetPort)"
            print("[INTERFACE_VM] Applying TCP: \(serverAddress)")
            activeInterfaceId = tcpIf.id
            interfaceStatus[tcpIf.id] = .connecting
            do {
                try await appServices.reconnectTCPOnly(host: config.targetHost, port: config.targetPort)
                showSuccess("Connecting to \(config.targetHost):\(config.targetPort)...")
            } catch {
                print("[INTERFACE_VM] TCP failed: \(error)")
                interfaceStatus[tcpIf.id] = .error
                showError("TCP failed: \(error.localizedDescription)")
            }
        } else if tcpEntity == nil && appServices.tcpInterface != nil {
            print("[INTERFACE_VM] Stopping TCP")
            await appServices.stopTCPInterface()
            activeInterfaceId = nil
        }

        // --- AutoInterface ---
        let autoEntity = enabledInterfaces.first(where: { $0.type == .autoInterface })
        if let autoIf = autoEntity,
           case .autoInterface(let config) = autoIf.config {
            if appServices.autoInterface == nil {
                let groupId = config.groupId ?? "reticulum"
                print("[INTERFACE_VM] Starting AutoInterface: \(groupId)")
                interfaceStatus[autoIf.id] = .connecting
                do {
                    try await appServices.startAutoInterface(groupId: groupId)
                    interfaceStatus[autoIf.id] = .connected
                } catch {
                    print("[INTERFACE_VM] Auto failed: \(error)")
                    interfaceStatus[autoIf.id] = .error
                }
            }
        } else if autoEntity == nil {
            await appServices.stopAutoInterface()
        }

        // --- BLE ---
        #if canImport(CoreBluetooth)
        let bleEntity = enabledInterfaces.first(where: { $0.type == .ble })
        if let bleEntity = bleEntity {
            if appServices.bleInterface == nil {
                print("[INTERFACE_VM] Starting BLE")
                interfaceStatus[bleEntity.id] = .connecting
                do {
                    try await appServices.startBLEInterface()
                    interfaceStatus[bleEntity.id] = .connected
                } catch {
                    print("[INTERFACE_VM] BLE failed: \(error)")
                    interfaceStatus[bleEntity.id] = .error
                    showError("BLE failed: \(error.localizedDescription)")
                }
            }
        } else if bleEntity == nil {
            await appServices.stopBLEInterface()
        }
        #endif

        // --- RNode ---
        let rnodeEntity = enabledInterfaces.first(where: { $0.type == .rnode })
        if let rnodeIf = rnodeEntity,
           case .rnode(let rnodeConfig) = rnodeIf.config {
            if appServices.rnodeInterface == nil {
                print("[INTERFACE_VM] Starting RNode: \(rnodeConfig.deviceName)")
                interfaceStatus[rnodeIf.id] = .connecting
                do {
                    try await appServices.startRNodeInterface(config: rnodeConfig, name: rnodeIf.name)
                } catch {
                    print("[INTERFACE_VM] RNode failed: \(error)")
                    interfaceStatus[rnodeIf.id] = .error
                    showError("RNode failed: \(error.localizedDescription)")
                }
            }
        } else if rnodeEntity == nil {
            await appServices.stopRNodeInterface()
        }

        hasPendingChanges = false
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
        statusObserverTask = Task.detached { [weak self] in
            // Initial sync: detect already-running TCP interface
            await MainActor.run {
                guard let self = self else { return }
                let enabledInterfaces = self.repository.getEnabledInterfaces()
                if let tcpEntity = enabledInterfaces.first(where: { $0.type == .tcpClient }),
                   self.appServices.tcpInterface != nil {
                    self.activeInterfaceId = tcpEntity.id
                }
            }

            while !Task.isCancelled {
                guard let self = self else { break }

                // Read @MainActor properties we need for actor lookups
                let (activeId, isConn, isReconn, connErr, autoIf, bleIf, rnodeIf, enabledIfs) = await MainActor.run {
                    (
                        self.activeInterfaceId,
                        self.appServices.isConnected,
                        self.appServices.isReconnecting,
                        self.appServices.connectionError,
                        self.appServices.autoInterface,
                        self.appServices.bleInterface,
                        self.appServices.rnodeInterface,
                        self.repository.getEnabledInterfaces()
                    )
                }

                // Read actor-isolated state OFF main thread
                var autoState: InterfaceState?
                var autoPeerCount: Int?
                if let auto = autoIf {
                    autoState = await auto.state
                    autoPeerCount = await auto.peerCount
                }

                var bleState: InterfaceState?
                var blePeerCount: Int?
                if let ble = bleIf {
                    bleState = await ble.state
                    blePeerCount = await ble.peerCount
                }

                var rnodeState: InterfaceState?
                if let rnode = rnodeIf {
                    rnodeState = await rnode.state
                }

                // Batch all UI mutations into single MainActor.run
                await MainActor.run {
                    // Track TCP interface status
                    if let interfaceId = activeId {
                        if isConn {
                            if self.interfaceStatus[interfaceId] != .connected {
                                self.interfaceStatus[interfaceId] = .connected
                                self.errorMessage = nil
                            }
                        } else if isReconn {
                            self.interfaceStatus[interfaceId] = .reconnecting
                            if let error = connErr,
                               self.errorMessage != error {
                                self.showError(error)
                            }
                        } else if connErr != nil {
                            self.interfaceStatus[interfaceId] = .error
                            if let error = connErr,
                               self.errorMessage != error {
                                self.showError(error)
                            }
                        }
                    }

                    // Track Auto interface status
                    if let autoEntity = enabledIfs.first(where: { $0.type == .autoInterface }) {
                        if let state = autoState {
                            switch state {
                            case .connected:
                                self.interfaceStatus[autoEntity.id] = .connected
                            case .connecting:
                                self.interfaceStatus[autoEntity.id] = .connecting
                            default:
                                if (autoPeerCount ?? 0) > 0 {
                                    self.interfaceStatus[autoEntity.id] = .connected
                                } else {
                                    self.interfaceStatus[autoEntity.id] = .disconnected
                                }
                            }
                        } else {
                            self.interfaceStatus[autoEntity.id] = .disconnected
                        }
                    }

                    // Track BLE interface status
                    if let bleEntity = enabledIfs.first(where: { $0.type == .ble }) {
                        if let state = bleState {
                            switch state {
                            case .connected:
                                self.interfaceStatus[bleEntity.id] = .connected
                            case .connecting:
                                self.interfaceStatus[bleEntity.id] = .connecting
                            default:
                                if (blePeerCount ?? 0) > 0 {
                                    self.interfaceStatus[bleEntity.id] = .connected
                                } else {
                                    self.interfaceStatus[bleEntity.id] = .disconnected
                                }
                            }
                        } else {
                            self.interfaceStatus[bleEntity.id] = .disconnected
                        }
                    }

                    // Track RNode interface status
                    if let rnodeEntity = enabledIfs.first(where: { $0.type == .rnode }) {
                        if let state = rnodeState {
                            switch state {
                            case .connected:
                                self.interfaceStatus[rnodeEntity.id] = .connected
                            case .connecting:
                                self.interfaceStatus[rnodeEntity.id] = .connecting
                            case .reconnecting:
                                self.interfaceStatus[rnodeEntity.id] = .reconnecting
                            case .disconnected:
                                self.interfaceStatus[rnodeEntity.id] = .disconnected
                            }
                        } else {
                            self.interfaceStatus[rnodeEntity.id] = .disconnected
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
        configAutoGroupId = "reticulum"
        configDeviceName = ""
        configFrequency = "915000000"
        configBandwidth = "125000"
        configTxPower = "17"
        configSpreadingFactor = "7"
        configCodingRate = "5"
        nameError = nil
        targetHostError = nil
        targetPortError = nil
        deviceNameError = nil
        frequencyError = nil
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

        case .ble:
            break // No type-specific fields to populate

        case .rnode(let config):
            configDeviceName = config.deviceName
            configFrequency = String(config.frequency)
            configBandwidth = String(config.bandwidth)
            configTxPower = String(config.txPower)
            configSpreadingFactor = String(config.spreadingFactor)
            configCodingRate = String(config.codingRate)
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

        case .rnode:
            return .rnode(RNodeConfig(
                deviceName: configDeviceName.trimmingCharacters(in: .whitespaces),
                frequency: UInt32(configFrequency) ?? 915_000_000,
                bandwidth: UInt32(configBandwidth) ?? 125_000,
                txPower: UInt8(configTxPower) ?? 17,
                spreadingFactor: UInt8(configSpreadingFactor) ?? 7,
                codingRate: UInt8(configCodingRate) ?? 5
            ))

        case .ble:
            return .ble(BLEConfig())
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

        case .rnode:
            let device = configDeviceName.trimmingCharacters(in: .whitespaces)
            if device.isEmpty {
                deviceNameError = "Device name is required"
                valid = false
            } else {
                deviceNameError = nil
            }

            if let freq = UInt32(configFrequency) {
                if freq < 137_000_000 || freq > 3_000_000_000 {
                    frequencyError = "Frequency must be 137 MHz - 3 GHz"
                    valid = false
                } else {
                    frequencyError = nil
                }
            } else {
                frequencyError = "Invalid frequency"
                valid = false
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
