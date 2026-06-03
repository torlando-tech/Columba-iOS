//
//  InterfaceManagementViewModel.swift
//  ColumbaApp
//
//  ViewModel for managing Reticulum network interface configurations.
//  Handles interface CRUD operations and connection state tracking.
//

import Foundation
import RNSAPI
import SwiftUI
import os.log

private let logger = Logger(subsystem: "network.columba.Columba", category: "InterfaceManagementVM")

// MARK: - Interface Management ViewModel

/// ViewModel for the interface management screen.
///
/// Manages interface list state, add/edit dialog state, and coordinates
/// with InterfaceRepository for persistence.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class InterfaceManagementViewModel: TCPClientWizardSaveSink {

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

    /// Whether the TCP client wizard is shown (community server picker → review/configure)
    public var showTCPWizard: Bool = false

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

    /// Toggle interface enabled state. Marks dirty; user must tap
    /// "Apply & Restart" in the toolbar to push the change through to
    /// Reticulum (which has no hot-reload — see `applyChanges()`).
    public func toggleInterface(_ interface: InterfaceEntity, enabled: Bool) {
        repository.toggleInterface(id: interface.id, enabled: enabled)
        hasPendingChanges = true
        showSuccess("\(interface.name) \(enabled ? "enabled" : "disabled") — tap Apply to restart")
    }

    /// Delete an interface. Marks dirty; the running Reticulum stack keeps
    /// the old interface alive until "Apply & Restart" is tapped.
    public func deleteInterface(_ interface: InterfaceEntity) {
        repository.deleteInterface(id: interface.id)
        hasPendingChanges = true
        showSuccess("Interface deleted — tap Apply to restart")
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
        } else if type == .tcpClient {
            showTCPWizard = true
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
        } else if interface.type == .tcpClient {
            showTCPWizard = true
        } else {
            showConfigSheet = true
        }
    }

    /// Dismiss the config sheet.
    public func dismissConfigSheet() {
        showConfigSheet = false
        showRNodeWizard = false
        showTCPWizard = false
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
            showSuccess("Interface updated — tap Apply to restart")
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
            showSuccess("Interface added — tap Apply to restart")
        }

        hasPendingChanges = true
        dismissConfigSheet()
        // Don't auto-apply — user taps "Apply & Restart" explicitly so
        // they're not surprised by a Reticulum restart while editing.
    }

    /// Save a TCP client interface from the wizard flow.
    ///
    /// Bypasses the form-field validation path (the wizard does its own validation
    /// in `canProceed`) and writes directly through the repository, then triggers
    /// the standard apply-changes pipeline.
    public func saveTCPInterface(
        editing: InterfaceEntity?,
        name: String,
        enabled: Bool,
        mode: InterfaceMode,
        config: TCPClientConfig
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let interfaceConfig: InterfaceTypeConfig = .tcpClient(config)

        if let existing = editing {
            var updated = existing
            updated.name = trimmedName
            updated.enabled = enabled
            updated.mode = mode
            updated.config = interfaceConfig
            repository.updateInterface(updated)
            showSuccess("Interface updated")
        } else {
            let newInterface = InterfaceEntity(
                name: trimmedName,
                type: .tcpClient,
                enabled: enabled,
                mode: mode,
                config: interfaceConfig
            )
            repository.addInterface(newInterface)
            showSuccess("Interface added")
        }

        hasPendingChanges = true
        dismissConfigSheet()

        Task { @MainActor in
            await applyChanges()
        }
    }

    // MARK: - Apply Changes

    /// Apply pending interface changes to the running Reticulum stack live —
    /// no restart, no relaunch.
    ///
    /// RNS attaches/detaches interfaces on a running `Transport` (the same
    /// primitive its interface-discovery autoconnect uses), so changing the
    /// `[interfaces]` set does NOT require a full `RNS.Reticulum(...)` re-init.
    /// `AppServices.applyInterfaceChanges()` diffs the saved enabled list
    /// against what's currently live and hot-adds / hot-removes the delta,
    /// while also rewriting the config file so the change survives a cold
    /// launch. New TCP interfaces connect within ~1-2s; removed ones drop
    /// immediately.
    @MainActor
    public func applyChanges() async {
        guard hasPendingChanges else { return }

        isApplyingChanges = true
        // Backend-agnostic Apply: route ALL interface changes (incl. multiple
        // TCP) through the active backend's hot add/remove path. This replaces
        // main's legacy per-TCP connectTCPInterface loop (the dual-backend
        // refactor moved TCP bring-up into appServices.applyInterfaceChanges()
        // so it works for the Swift backend too). Multi-TCP reconciliation with
        // main's per-entity tcpInterfaces/tcpEndpoints tracking is deferred to
        // the dual-backend landing.
        defer {
            hasPendingChanges = false
            isApplyingChanges = false
        }

        logger.info("Applying interface changes live (hot add/remove)")
        await appServices.applyInterfaceChanges()
        showSuccess("Interface changes applied")
    }

    // MARK: - Status Observation

    /// Start polling AppServices connection state to update interface status.
    private func startStatusObserver() {
        statusObserverTask?.cancel()
        statusObserverTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                // Read @MainActor properties we need for actor lookups
                let (tcpEntities, tcpIfaces, autoIf, bleIf, rnodeIf, mpcIf, enabledIfs, appSvc) = await MainActor.run {
                    (
                        self.repository.getEnabledInterfaces().filter { $0.type == .tcpClient },
                        self.appServices.tcpInterfaces,
                        self.appServices.autoInterface,
                        self.appServices.bleInterface,
                        self.appServices.rnodeInterface,
                        self.appServices.mpcInterface,
                        self.repository.getEnabledInterfaces(),
                        self.appServices
                    )
                }

                // Read TCP interface states off main thread
                var tcpUpdates: [(String, InterfaceStatus, String?)] = []
                if BackendPreference.modelB {
                    // Model B: the app owns no local TCP interface — the NE owns
                    // the relay socket. Reflect the NE's relay status (via the
                    // proxy statusSnapshot) so the card isn't stuck "disconnected"
                    // while the NE relay is actually connected.
                    let relayOnline = await appSvc.neTcpRelayOnline()
                    let neStatus: InterfaceStatus = relayOnline ? .connected : .connecting
                    for entity in tcpEntities {
                        tcpUpdates.append((entity.id, neStatus, nil))
                    }
                } else {
                    for entity in tcpEntities {
                        if let iface = tcpIfaces[entity.id] {
                            let state = await iface.state
                            let err = await iface.lastErrorDescription
                            let status: InterfaceStatus
                            switch state {
                            case .connected: status = .connected
                            case .connecting: status = .connecting
                            case .reconnecting: status = .reconnecting
                            case .disconnected, .notConnected: status = .disconnected
                            case .connectionFailed, .sendFailed, .invalidConfig: status = .error
                            }
                            tcpUpdates.append((entity.id, status, err))
                        } else {
                            tcpUpdates.append((entity.id, .disconnected, nil))
                        }
                    }
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

                var mpcState: InterfaceState?
                var mpcPeerCount: Int?
                if let mpc = mpcIf {
                    mpcState = await mpc.state
                    mpcPeerCount = await mpc.peerCount
                }

                // Batch all UI mutations into single MainActor.run
                await MainActor.run {
                    // Update TCP interface statuses
                    for (id, status, err) in tcpUpdates {
                        self.interfaceStatus[id] = status
                        if (status == .reconnecting || status == .error),
                           let e = err, self.errorMessage != e {
                            self.showError(e)
                        }
                        if status == .connected {
                            self.errorMessage = nil
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
                            case .disconnected, .notConnected:
                                self.interfaceStatus[rnodeEntity.id] = .disconnected
                            case .connectionFailed, .sendFailed, .invalidConfig:
                                self.interfaceStatus[rnodeEntity.id] = .error
                            }
                        } else {
                            self.interfaceStatus[rnodeEntity.id] = .disconnected
                        }
                    }

                    // Track MPC interface status
                    // Parent is always .connected once advertising — use peer count
                    // to distinguish "active with peers" from "browsing, no peers"
                    if let mpcEntity = enabledIfs.first(where: { $0.type == .multipeer }) {
                        if let state = mpcState {
                            switch state {
                            case .connected:
                                if (mpcPeerCount ?? 0) > 0 {
                                    self.interfaceStatus[mpcEntity.id] = .connected
                                } else {
                                    self.interfaceStatus[mpcEntity.id] = .connecting
                                }
                            case .connecting:
                                self.interfaceStatus[mpcEntity.id] = .connecting
                            default:
                                self.interfaceStatus[mpcEntity.id] = .disconnected
                            }
                        } else {
                            self.interfaceStatus[mpcEntity.id] = .disconnected
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

        case .multipeer:
            break // No type-specific fields to populate
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

        case .multipeer:
            return .multipeer(MultipeerConfig())
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
