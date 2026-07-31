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

    /// Whether interface edits require an explicit "Apply" tap to take effect.
    ///
    /// On the Swift / Model B build the NE live-reconciles every change the
    /// instant it's saved — `InterfaceRepository.saveInterfaces()` posts
    /// `configChanged` on each edit, which the NE observes (and
    /// `AppServices.applyInterfaceChanges()` is a deliberate no-op on Model B).
    /// So there is no Apply step: the toolbar omits the button and edit toasts
    /// don't prompt for it. On the Python build, edits are staged and pushed to
    /// the running stack only on Apply.
    public var requiresExplicitApply: Bool { !BackendPreference.modelB }

    /// Trailing hint for edit toasts — prompt to Apply only when an explicit
    /// Apply is required; on the live (Model B) path the change is already in
    /// effect, so no prompt is shown.
    private var applyHint: String { requiresExplicitApply ? " — tap Apply to take effect" : "" }

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

    /// Selection waiting for the type-selector sheet to finish dismissing.
    /// SwiftUI ignores a second modal presentation requested during dismissal,
    /// so routing to a wizard/config sheet must happen from the sheet's onDismiss.
    public var pendingInterfaceTypeSelection: InterfaceType?

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
    public var configDeviceIdentifier: UUID?
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

    /// Status observation task — polls APP-LOCAL interface state (MPC /
    /// MultipeerConnectivity, Auto, RNode, and the Model-A local TCP/BLE
    /// Compat actors). It does NOT touch the NE: the Model-B BLE badge is
    /// refreshed event-driven via `networkStateChangedObserver` below.
    private var statusObserverTask: Task<Void, Never>?

    /// In-process observer for `NotificationObserver.networkStateChangedInApp`.
    /// The NE PUSHES this on BLE/interface change; we fetch the NE-derived BLE
    /// badge once per notification instead of polling the NE on the 1s timer.
    private var networkStateChangedObserver: NSObjectProtocol?

    /// Latest NE-derived BLE badge values (Model B only), populated by the
    /// event-driven `refreshNEBackedStatus()` and consumed by the status
    /// loop / `interfaceStatus` write. Under Model B the BLE radio + interface
    /// live across the NE seam, so these are the only source of truth for the
    /// badge; the 1s loop must NOT round-trip the NE to derive them.
    @MainActor private var modelBBLEPeerCount: Int = 0
    @MainActor private var modelBBLEState: InterfaceState = .disconnected

    /// Latest NE-derived PER-RELAY status (Model B only), keyed by interface entity id,
    /// populated by the event-driven `refreshNEBackedStatus()` and read back by the 1s
    /// status loop. Each `ne-tcp-relay-<id>` interface maps to its own badge so one dead
    /// relay shows "Unreachable" while a reachable one shows "Connected" — the coarse
    /// any-relay-online bool can't express that. NE-push driven (no per-second round-trip).
    @MainActor private var modelBRelayStatuses: [String: InterfaceStatus] = [:]
    /// NE-authoritative RNode badge (Model B), cached by `refreshNEBackedStatus`. Only drives
    /// the badge when `AppServices.rnodeBadgeFromNE` is on (gated — RISK 1); otherwise the
    /// app-side BLE link owns the RNode badge.
    @MainActor private var modelBRNodeStatus: InterfaceStatus?

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
        startNetworkStateObserver()
    }

    deinit {
        // Tear down the app-local status poll and the NE push observer. The loop
        // also self-exits via its `[weak self]` guard, but cancel explicitly so
        // it stops promptly rather than after the next 1s sleep.
        statusObserverTask?.cancel()
        if let observer = networkStateChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - List Operations

    /// Load interfaces from repository.
    public func loadInterfaces() {
        isLoading = true
        repository.loadInterfaces()
        isLoading = false
    }

    /// Toggle interface enabled state. On Model B the change is live the moment
    /// it's saved; on Python it's staged until the user taps "Apply"
    /// (see `requiresExplicitApply` / `applyChanges()`).
    public func toggleInterface(_ interface: InterfaceEntity, enabled: Bool) {
        if interface.type == .rnode, enabled {
            if BackendPreference.modelB,
               otherEnabledRNodeExists(excluding: interface.id) {
                showError("This build currently supports one active RNode. Disable the other RNode first.")
                return
            }
            if !BackendPreference.modelB,
               case .rnode(let config) = interface.config,
               otherEnabledRNodeTargetsSamePhysicalDevice(
                   identifier: config.deviceIdentifier,
                   name: config.deviceName,
                   excluding: interface.id
               ) {
                showError("That physical RNode is already used by another active interface.")
                return
            }
        }
        repository.toggleInterface(id: interface.id, enabled: enabled)
        hasPendingChanges = true
        applyRNodeLiveChange(config: interface.config, name: interface.name, enabled: enabled)
        showSuccess("\(interface.name) \(enabled ? "enabled" : "disabled")\(applyHint)")
    }

    /// Delete an interface. On Model B it's removed live; on Python the running
    /// stack keeps the old interface alive until "Apply" is tapped.
    public func deleteInterface(_ interface: InterfaceEntity) {
        repository.deleteInterface(id: interface.id)
        hasPendingChanges = true
        // Tear down the app-side RNode radio when its interface is removed.
        applyRNodeLiveChange(config: interface.config, name: interface.name, enabled: false)
        showSuccess("Interface deleted\(applyHint)")
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
        pendingInterfaceTypeSelection = nil
        showTypeSelector = true
    }

    /// Dismiss the type selector first; the owning view calls
    /// `completePendingInterfaceTypeSelection()` from its `onDismiss` callback.
    public func queueInterfaceTypeSelection(_ type: InterfaceType) {
        pendingInterfaceTypeSelection = type
        showTypeSelector = false
    }

    /// Route only after the selector sheet is fully gone, avoiding competing
    /// sheet/full-screen-cover presentations in the same SwiftUI update cycle.
    public func completePendingInterfaceTypeSelection() {
        guard let type = pendingInterfaceTypeSelection else { return }
        pendingInterfaceTypeSelection = nil
        selectInterfaceType(type)
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

        if configType == .rnode, configEnabled {
            if BackendPreference.modelB,
               otherEnabledRNodeExists(excluding: editingInterface?.id) {
                showError("This build currently supports one active RNode. Disable the other RNode first.")
                return
            }
            if !BackendPreference.modelB,
               otherEnabledRNodeTargetsSamePhysicalDevice(
                   identifier: configDeviceIdentifier,
                   name: configDeviceName,
                   excluding: editingInterface?.id
               ) {
                showError("That physical RNode is already used by another active interface.")
                return
            }
        }

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
            showSuccess("Interface updated\(applyHint)")
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
            // RNode bring-up is async (radio in app, RNS in NE); don't claim "added"
            // as if it's connected — the badge + a failure toast report the outcome.
            if configType == .rnode, BackendPreference.modelB {
                showSuccess("RNode saved — connecting…")
            } else {
                showSuccess("Interface added\(applyHint)")
            }
        }

        hasPendingChanges = true
        // On Model B the app hosts the CoreBluetooth RNode radio, so a saved RNode
        // add/edit must start (or stop) the app-side radio NOW — the NE's
        // `configChanged` reconcile only covers TCP relays and cannot start the
        // app's radio. Read configName/configEnabled BEFORE dismissConfigSheet()
        // resets the form. Other interface types stay live-reconciled by the NE.
        applyRNodeLiveChange(config: config, name: configName, enabled: configEnabled)
        dismissConfigSheet()
        // On Python, don't auto-apply — the user taps "Apply" explicitly so a
        // mid-edit change isn't pushed to the live stack until they're ready.
        // On Model B there's no Apply step; the change is already live (the NE
        // reconciles on save), so `requiresExplicitApply` hides the button.
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

    /// Bring an RNode interface change live immediately on Model B.
    ///
    /// Unlike TCP relays — which the NE live-reconciles off the `configChanged`
    /// notification the repository posts on every save — the RNode radio lives in
    /// the **app** (the NE runs only the RNS/KISS stack over the App-Group seam).
    /// So an RNode add / edit / enable / disable / remove must (re)start or stop
    /// the app-side radio here: `startRNodeInterface` starts the app-side seam
    /// server AND writes the `RNodeSeamConfig` the NE rebuilds its
    /// `RNodeInterface` from (which then drives the BLE connect back over the
    /// seam). Without this hook a freshly-added RNode never connects until the
    /// next cold launch (`ColumbaApp` startup brings up persisted enabled RNodes),
    /// which presents as a dead "connect" — the app and the RNode both show BLE
    /// disconnected. No-op on Python (explicit Apply) and for non-RNode types.
    private func applyRNodeLiveChange(config: InterfaceTypeConfig, name: String, enabled: Bool) {
        guard BackendPreference.modelB, case .rnode(let rnodeConfig) = config else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            do {
                if enabled {
                    try await appServices.startRNodeInterface(config: rnodeConfig, name: trimmedName)
                } else if !otherEnabledRNodeExists() {
                    // Only tear down the shared radio when no enabled RNode remains
                    // (the repo entity is already disabled/removed by this point).
                    await appServices.stopRNodeInterface()
                }
            } catch {
                logger.error("RNode live bring-up failed: \(error.localizedDescription)")
                showError("Couldn't start RNode: \(error.localizedDescription)")
            }
        }
    }

    /// Model B currently owns one app-group seam. Shipping Python instead uses
    /// independent native sessions and checks physical-device identity below.
    private func otherEnabledRNodeExists(excluding id: String? = nil) -> Bool {
        interfaces.contains { $0.type == .rnode && $0.enabled && $0.id != id }
    }

    private func otherEnabledRNodeTargetsSamePhysicalDevice(
        identifier: UUID?,
        name: String,
        excluding id: String? = nil
    ) -> Bool {
        return interfaces.contains { entity in
            guard entity.type == .rnode, entity.enabled, entity.id != id,
                  case .rnode(let config) = entity.config else { return false }
            // Concurrent operation is allowed only when every participant has
            // a stable physical UUID. A legacy name-only target cannot prove
            // that it is distinct from another peripheral.
            guard let identifier,
                  let existingIdentifier = config.deviceIdentifier else { return true }
            return identifier == existingIdentifier
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
                    // Model B: the app owns no local TCP interface — the NE owns each
                    // relay socket. Read back the PER-RELAY status cached by the
                    // event-driven `refreshNEBackedStatus()` (NE-push, not a per-second
                    // round-trip) so each relay's badge reflects its own reachability and
                    // the card isn't stuck "disconnected" while a relay is actually up. A
                    // relay the NE hasn't registered yet (just added) defaults to connecting.
                    let cached = await MainActor.run { self.modelBRelayStatuses }
                    for entity in tcpEntities {
                        tcpUpdates.append((entity.id, cached[entity.id] ?? .connecting, nil))
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
                if BackendPreference.modelB {
                    // Model B: reticulum-swift's `BLEInterface` runs in the NE, not
                    // the app's Compat `bleIf`. This used to round-trip the NE every
                    // 1s (`appSvc.getBLEConnectionInfos()`) — part of the ~10/s app↔NE
                    // IPC flood we're eliminating. The badge is now EVENT-DRIVEN: the
                    // NE pushes `networkStateChangedInApp` on change and
                    // `refreshNEBackedStatus()` fetches once into these cached
                    // values, which we just read back here (no NE I/O on the timer).
                    blePeerCount = await MainActor.run { self.modelBBLEPeerCount }
                    bleState = await MainActor.run { self.modelBBLEState }
                } else if let ble = bleIf {
                    bleState = await ble.state
                    blePeerCount = await ble.peerCount
                }

                var rnodeState: InterfaceState?
                if let rnode = rnodeIf {
                    rnodeState = await rnode.state
                }

                var pythonRNodeUpdates: [(String, String, InterfaceStatus)] = []
                #if COLUMBA_RUNTIME_PYTHON
                for entity in enabledIfs where entity.type == .rnode {
                    guard case .rnode(let config) = entity.config else { continue }
                    let state = PythonRNodeBLESessionRegistry.shared.snapshot(
                        deviceIdentifier: config.deviceIdentifier,
                        deviceName: config.deviceName
                    )?.0
                    let status: InterfaceStatus
                    switch state {
                    case .connected: status = .connected
                    case .connecting: status = .connecting
                    case .failed: status = .error
                    case .disconnected, .none: status = .disconnected
                    }
                    pythonRNodeUpdates.append((entity.id, entity.name, status))
                }
                #endif

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
                    #if COLUMBA_RUNTIME_PYTHON
                    for (id, name, status) in pythonRNodeUpdates {
                        if self.interfaceStatus[id] != status {
                            DiagLog.log("[RNODE_UI] \(name) badge -> \(status.displayName)")
                        }
                        self.interfaceStatus[id] = status
                    }
                    #else
                    if let rnodeEntity = enabledIfs.first(where: { $0.type == .rnode }) {
                        if AppServices.rnodeBadgeFromNE {
                            // GATED: NE-authoritative badge. refreshNEBackedStatus published
                            // it on the push; mirror it here so the per-tick loop doesn't
                            // revert to the (now-suppressed) BLE-link state.
                            let neStatus = self.modelBRNodeStatus ?? .connecting
                            self.interfaceStatus[rnodeEntity.id] = neStatus
                            if neStatus == .error {
                                let msg = "RNode \(rnodeEntity.name) couldn't connect"
                                if self.errorMessage != msg { self.showError(msg) }
                            }
                        } else if let state = rnodeState {
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
                                // Surface the failure as a toast (mirrors the TCP path);
                                // the dedup guard prevents per-tick re-flapping.
                                let msg = "RNode \(rnodeEntity.name) couldn't connect"
                                if self.errorMessage != msg { self.showError(msg) }
                            }
                        } else {
                            self.interfaceStatus[rnodeEntity.id] = .disconnected
                        }
                    }
                    #endif

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

    /// Observe the NE's push channel for BLE/interface-state changes and refresh
    /// the NE-derived BLE badge once per notification (plus one initial fetch),
    /// instead of polling the NE on the 1s status loop.
    ///
    /// Only the NE-backed BLE badge moves here; APP-LOCAL interface state (MPC,
    /// Auto, RNode, Model-A local TCP/BLE) stays on `startStatusObserver`'s timer
    /// because it has no Darwin/push signal. Under Model A this is effectively a
    /// no-op refresh (the badge comes from the local `bleIf` actor in the loop).
    private func startNetworkStateObserver() {
        // One initial refresh so the badge is correct before the first push.
        Task { @MainActor [weak self] in
            await self?.refreshNEBackedStatus()
        }

        // Refresh once per NE push. The NE coalesces state changes and posts
        // `networkStateChangedInApp`; we fetch once in response (no timer).
        networkStateChangedObserver = NotificationCenter.default.addObserver(
            forName: NotificationObserver.networkStateChangedInApp,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNEBackedStatus()
            }
        }
    }

    /// Fetch the NE-derived interface badges (BLE peer count + per-relay TCP status)
    /// exactly once and publish them to `interfaceStatus`. This is the ONLY place that
    /// round-trips the NE for these; it runs on NE push, never on a timer.
    ///
    /// Under Model A the NE doesn't own these interfaces, so there's nothing to pull over
    /// the seam — the local actors read in `startStatusObserver` remain the source of
    /// truth and this returns early.
    @MainActor
    private func refreshNEBackedStatus() async {
        guard BackendPreference.modelB else { return }

        // --- BLE badge (single NE round-trip; replaces the per-second poll). ---
        let count = await appServices.getBLEConnectionInfos().count
        let state: InterfaceState = count > 0 ? .connected : .disconnected
        // Cache for the status loop's BLE-badge write (Model B branch reads these back).
        modelBBLEPeerCount = count
        modelBBLEState = state
        // Publish immediately too, so the badge updates on the push rather than waiting
        // up to ~1s for the next loop tick.
        if let bleEntity = repository.getEnabledInterfaces().first(where: { $0.type == .ble }) {
            interfaceStatus[bleEntity.id] = count > 0 ? .connected : .disconnected
        }

        // --- Per-relay TCP status (one snapshot covering every `ne-tcp-relay-<id>`). ---
        // Map the NE's online + lastError to a per-relay badge: online ⇒ connected; down
        // with an error ⇒ error ("Unreachable", honest about a relay that won't connect);
        // down with no error yet ⇒ connecting. No per-relay toast — the badge carries it
        // (a global error toast flapped between relays every second).
        let relayStatuses = await appServices.neTcpRelayStatuses()
        var fresh: [String: InterfaceStatus] = [:]
        for relay in relayStatuses {
            let status: InterfaceStatus
            if relay.online {
                status = .connected
            } else if let err = relay.lastError, !err.isEmpty {
                status = .error
            } else {
                status = .connecting
            }
            fresh[relay.entityId] = status
        }
        modelBRelayStatuses = fresh
        // Publish immediately so the badges update on the push, not the next tick.
        for entity in repository.getEnabledInterfaces() where entity.type == .tcpClient {
            interfaceStatus[entity.id] = fresh[entity.id] ?? .connecting
        }

        // --- RNode badge (NE-authoritative). GATED: skip the statusSnapshot() IPC entirely
        //     when the flag is off — the app-side BLE link owns the RNode badge then (see
        //     applyRNodeLinkState). Only query + drive the badge when the flag is on. ---
        if AppServices.rnodeBadgeFromNE {
            if let rnode = await appServices.neRNodeStatus() {
                let status: InterfaceStatus
                if rnode.online {
                    status = .connected
                } else if let err = rnode.lastError, !err.isEmpty {
                    status = .error
                } else {
                    status = .connecting
                }
                modelBRNodeStatus = status
                if let rnodeEntity = repository.getEnabledInterfaces().first(where: { $0.type == .rnode }) {
                    interfaceStatus[rnodeEntity.id] = status
                }
            } else {
                modelBRNodeStatus = nil
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
        configDeviceIdentifier = nil
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
            configDeviceIdentifier = config.deviceIdentifier
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
                deviceIdentifier: configDeviceIdentifier,
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
