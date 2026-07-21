//
//  OnboardingViewModel.swift
//  ColumbaApp
//
//  State management and completion logic for the onboarding flow.
//  Creates identity, interfaces, and marks onboarding complete.
//

import Foundation
import RNSAPI
import Observation
import UserNotifications
import CoreBluetooth

private enum OnboardingFlowError: LocalizedError {
    case operationInProgress
    case noRestoredIdentity

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Setup is already in progress. Please wait and try again."
        case .noRestoredIdentity:
            return "The backup did not contain an identity that can be activated."
        }
    }
}

/// Manages onboarding flow state and persists selections on completion.
@available(iOS 17.0, macOS 14.0, *)
@Observable
@MainActor
final class OnboardingViewModel {
    // MARK: - State

    var currentPage: Int = 0
    var displayName: String = ""
    var selectedInterfaces: Set<OnboardingInterfaceType> = [.tcp]
    var selectedTcpServer: TcpCommunityServer? = nil
    var notificationsGranted: Bool = false
    /// Current CoreBluetooth authorization. Under Model B the APP runs the CoreBluetooth
    /// host (the NE can't), so the BLE prompt would otherwise fire un-guided after
    /// onboarding when `ModelBBLEService` starts — surfacing it on the Permissions page
    /// keeps it inside the flow.
    var bluetoothAuthorization: CBManagerAuthorization = CBCentralManager.authorization
    var bluetoothGranted: Bool {
        #if COLUMBA_RUNTIME_MODEL_B
        bluetoothAuthorization == .allowedAlways && ModelBBLEService.isUserOptedIn
        #else
        bluetoothAuthorization == .allowedAlways
        #endif
    }
    @ObservationIgnored private var bluetoothProbe: BluetoothPermissionProbe?
    var isSaving: Bool = false

    /// Identity created during onboarding (set by prepareIdentity).
    var createdIdentity: LocalIdentity?
    /// QR code string for the created identity.
    var qrCodeString: String = ""

    /// Total number of onboarding pages.
    #if COLUMBA_RUNTIME_MODEL_B
    static let pageCount = 6
    #else
    static let pageCount = 5
    #endif

    // MARK: - Computed

    var effectiveDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Anonymous Peer"
            : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var selectedInterfaceNames: String {
        OnboardingInterfaceType.allCases
            .filter { selectedInterfaces.contains($0) }
            .map { $0.shortName }
            .joined(separator: ", ")
    }

    // MARK: - Navigation

    func nextPage() {
        if currentPage < Self.pageCount - 1 {
            currentPage += 1
        }
    }

    func previousPage() {
        if currentPage > 0 {
            currentPage -= 1
        }
    }

    // MARK: - Notification Permission

    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            notificationsGranted = granted
        } catch {
            notificationsGranted = false
        }
    }

    func checkNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsGranted = settings.authorizationStatus == .authorized
    }

    // MARK: - Bluetooth Permission

    /// Trigger the iOS Bluetooth prompt now (creating a CBCentralManager is what fires
    /// it) so the user grants/denies it INSIDE onboarding instead of being surprised by
    /// it after, when `ModelBBLEService` starts the app-side CoreBluetooth host.
    func requestBluetoothPermission() {
        #if COLUMBA_RUNTIME_MODEL_B
        // The Model B host must not construct its CoreBluetooth driver unless the user
        // explicitly opted in from this permission card.
        ModelBBLEService.recordUserOptIn()
        #endif
        bluetoothProbe = BluetoothPermissionProbe { [weak self] auth in
            Task { @MainActor in self?.bluetoothAuthorization = auth }
        }
    }

    func checkBluetoothStatus() {
        bluetoothAuthorization = CBCentralManager.authorization
    }

    // MARK: - Identity Preparation

    /// Create the identity eagerly so the QR code is available on the complete page.
    func prepareIdentity(identityManager: IdentityManager) async {
        guard qrCodeString.isEmpty else { return }
        do {
            try beginSaving()
            defer { isSaving = false }
            let local = try await createOrResumeIdentity(
                displayName: effectiveDisplayName,
                identityManager: identityManager
            )
            let identity = try await identityManager.loadIdentityKeys(for: local.identityHash)

            // Build QR string: lxma://<dest_hash>:<public_key_hex>
            let pubKeyHex = identity.publicKeys.map { String(format: "%02x", $0) }.joined()
            qrCodeString = "lxma://\(local.destinationHash):\(pubKeyHex)"
        } catch {
            // Non-fatal — QR just won't be available
        }
    }

    // MARK: - Completion

    /// Complete onboarding with user's selections.
    ///
    /// Uses the identity already created by prepareIdentity, or creates one if needed.
    func completeOnboarding(
        identityManager: IdentityManager,
        settingsRepository: SettingsRepository
    ) async throws {
        try beginSaving()
        defer { isSaving = false }

        // 1. Resume the identity persisted by preparation/a prior failed activation,
        // or create and retain one before any subsequent throwing operation.
        let local = try await createOrResumeIdentity(
            displayName: effectiveDisplayName,
            identityManager: identityManager
        )
        let _ = try await identityManager.switchToIdentity(local.identityHash)

        // 2. Save display name to settings
        await settingsRepository.setDisplayName(effectiveDisplayName)

        // 3. Create selected interfaces
        let interfaceRepo = InterfaceRepository()
        createInterfaces(in: interfaceRepo)

        // 4. Save notification preference
        if notificationsGranted {
            UserDefaults.standard.set(true, forKey: "notifications_enabled")
        }

        // 5. Mark onboarding and settings as initialized
        UserDefaults.standard.set(true, forKey: "has_completed_onboarding")
        UserDefaults.standard.set(true, forKey: "settings_initialized")

        // 6. If user opted into RNode, flag the shell to open the configuration
        // wizard once MainTabView is on screen. Only meaningful on iOS — the
        // RNode wizard's fullScreenCover is iOS-only.
        #if os(iOS)
        if selectedInterfaces.contains(.rnode) {
            UserDefaults.standard.set(true, forKey: Self.pendingRNodeSetupKey)
        }
        #endif
    }

    /// UserDefaults key for signalling that onboarding requested the RNode
    /// configuration wizard. Consumed by MainTabView on first appearance.
    static let pendingRNodeSetupKey = "pendingRNodeSetup"

    /// Skip onboarding with safe defaults.
    func skipOnboarding(
        identityManager: IdentityManager,
        settingsRepository: SettingsRepository
    ) async throws {
        try beginSaving()
        defer { isSaving = false }

        let requestedName = createdIdentity?.displayName ?? "Anonymous Peer"
        let local = try await createOrResumeIdentity(
            displayName: requestedName,
            identityManager: identityManager
        )
        let _ = try await identityManager.switchToIdentity(local.identityHash)

        await settingsRepository.setDisplayName(local.displayName)

        // A skipped setup always needs the canonical default relay, regardless of
        // Connectivity-page selections. Use the shared idempotent path so repeated
        // Skip/restore actions do not append duplicates.
        seedDefaultTcpInterface(in: InterfaceRepository())

        UserDefaults.standard.set(true, forKey: "has_completed_onboarding")
        UserDefaults.standard.set(true, forKey: "settings_initialized")
    }

    /// Finish a restore by activating a cryptographically validated identity from the backup.
    /// Never creates a replacement identity: a missing restored identity remains a retryable error.
    func completeRestoredOnboarding(
        preferredIdentityHash: String?,
        identityManager: IdentityManager,
        settingsRepository: SettingsRepository
    ) async throws {
        try beginSaving()
        defer { isSaving = false }

        guard let preferredIdentityHash,
              let local = await identityManager.getAllIdentities().first(where: {
                  $0.identityHash == preferredIdentityHash
              }) else {
            throw OnboardingFlowError.noRestoredIdentity
        }
        createdIdentity = local
        let _ = try await identityManager.switchToIdentity(local.identityHash)
        await settingsRepository.setDisplayName(local.displayName)
        seedDefaultTcpInterface(in: InterfaceRepository())
        UserDefaults.standard.set(true, forKey: "has_completed_onboarding")
        UserDefaults.standard.set(true, forKey: "settings_initialized")
    }

    // MARK: - Onboarding Check

    /// Whether onboarding has been completed.
    static var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "has_completed_onboarding")
    }

    /// Migrate existing users: if identities exist but onboarding flag is not set, set it.
    static func migrateExistingUsers() {
        if !hasCompletedOnboarding {
            if let data = UserDefaults.standard.data(forKey: "localIdentities"),
               let identities = try? JSONDecoder().decode([LocalIdentity].self, from: data),
               !identities.isEmpty {
                UserDefaults.standard.set(true, forKey: "has_completed_onboarding")
            }
        }
    }

    // MARK: - Private

    /// MainActor isolation makes this check-and-set atomic before either operation's
    /// first suspension point, preventing duplicate identities from concurrent taps.
    private func beginSaving() throws {
        guard !isSaving else { throw OnboardingFlowError.operationInProgress }
        isSaving = true
    }

    /// Identity creation persists immediately. Retain that record before key loading or
    /// activation can throw so retries resume it rather than creating orphan duplicates.
    private func createOrResumeIdentity(
        displayName: String,
        identityManager: IdentityManager
    ) async throws -> LocalIdentity {
        if let createdIdentity { return createdIdentity }
        let local = try await identityManager.createIdentity(displayName: displayName)
        createdIdentity = local
        return local
    }

    /// Seed the chosen TCP relay into the SHARED interface store. MUST run before the
    /// NE is started (on the Background-Delivery step) — the in-NE node reads its relay
    /// from this store ONCE at start (`loadTCPRelayConfig`) and has no observer to pick
    /// up a later write, so seeding after the NE boots leaves it "AppGroupBridge only"
    /// with no TCP path. Idempotent (it also runs again from completeOnboarding).
    func seedInterfaces(in repo: InterfaceRepository = InterfaceRepository()) {
        createInterfaces(in: repo)
    }

    /// Skip is deliberately independent of mutable Connectivity-page state: it always
    /// provides the canonical public relay and remains safe to invoke repeatedly.
    func seedDefaultTcpInterface(in repo: InterfaceRepository = InterfaceRepository()) {
        let server = TcpCommunityServer.defaultServer
        ensureInterfaceEnabled(InterfaceEntity(
            name: server.name,
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(
                targetHost: server.host,
                targetPort: server.port
            ))
        ), in: repo)
    }

    private func createInterfaces(in repo: InterfaceRepository) {
        #if COLUMBA_RUNTIME_MODEL_B
        // Model B's Network Extension owns its local transports and reads one TCP relay
        // from the shared store. Seed only that relay and keep the operation idempotent.
        let server = selectedTcpServer ?? TcpCommunityServer.defaultServer
        ensureInterfaceEnabled(InterfaceEntity(
            name: server.name,
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(
                targetHost: server.host,
                targetPort: server.port
            ))
        ), in: repo)
        #else
        // The shipping runtime owns these interfaces in the app process. Build a
        // canonical candidate for each selection and add it only if an equivalent
        // interface is not already stored. This makes completion safe to retry.
        for interfaceType in selectedInterfaces {
            let candidate: InterfaceEntity?
            switch interfaceType {
            case .auto:
                candidate = InterfaceEntity(
                    name: "Auto Discovery",
                    type: .autoInterface,
                    config: .autoInterface(AutoInterfaceConfig())
                )
            case .nearby:
                // Kept in the enum for stored-config compatibility, but shipping has no
                // Python MultipeerConnectivity transport and must not persist a new one.
                candidate = nil
            case .ble:
                candidate = InterfaceEntity(
                    name: "Bluetooth LE",
                    type: .ble,
                    config: .ble(BLEConfig())
                )
            case .tcp:
                let server = selectedTcpServer ?? TcpCommunityServer.defaultServer
                candidate = InterfaceEntity(
                    name: server.name,
                    type: .tcpClient,
                    config: .tcpClient(TCPClientConfig(
                        targetHost: server.host,
                        targetPort: server.port
                    ))
                )
            case .rnode:
                candidate = nil
            }

            guard let candidate else { continue }
            ensureInterfaceEnabled(candidate, in: repo)
        }
        #endif
    }

    /// Preserve one equivalent configuration and make sure it is enabled. Restore may
    /// import a disabled matching record; skip/completion must reactivate that record
    /// instead of appending a duplicate or leaving the app without a usable path.
    private func ensureInterfaceEnabled(
        _ candidate: InterfaceEntity,
        in repo: InterfaceRepository
    ) {
        if repo.interfaces.contains(where: { $0.enabled && interfacesAreEquivalent($0, candidate) }) {
            return
        }
        if var disabled = repo.interfaces.first(where: { !$0.enabled && interfacesAreEquivalent($0, candidate) }) {
            disabled.enabled = true
            repo.updateInterface(disabled)
            return
        }
        repo.addInterface(candidate)
    }

    private func interfacesAreEquivalent(
        _ existing: InterfaceEntity,
        _ candidate: InterfaceEntity
    ) -> Bool {
        existing.type == candidate.type
            && existing.mode == candidate.mode
            && existing.config == candidate.config
    }
}

// MARK: - Interface Type

/// Interface types available during onboarding.
enum OnboardingInterfaceType: String, CaseIterable, Hashable {
    case auto
    case nearby
    case ble
    case tcp
    case rnode

    var title: String {
        switch self {
        case .auto: return "Local WiFi"
        case .nearby: return "Nearby"
        case .ble: return "Bluetooth LE"
        case .tcp: return "Internet (TCP)"
        case .rnode: return "LoRa Radio"
        }
    }

    var shortName: String {
        switch self {
        case .auto: return "WiFi"
        case .nearby: return "Nearby"
        case .ble: return "BLE"
        case .tcp: return "TCP"
        case .rnode: return "LoRa"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "wifi"
        case .nearby: return "apple.logo"
        case .ble: return "wave.3.right"
        case .tcp: return "globe"
        case .rnode: return "radio"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Discover peers on your local network"
        case .nearby: return "Connect directly with nearby Apple devices"
        case .ble: return "Connect directly to nearby devices"
        case .tcp: return "Connect to the global Reticulum network"
        case .rnode: return "Long-range mesh via RNode hardware"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: return "No internet required"
        case .nearby: return "Apple devices only, no WiFi needed"
        case .ble: return "Requires Bluetooth permissions"
        case .tcp: return "Requires internet connection"
        case .rnode: return "Configure in Settings after setup"
        }
    }
}

/// Triggers the iOS Bluetooth permission dialog by initializing a CBCentralManager
/// (iOS prompts on first creation when authorization is `.notDetermined`) and reports
/// the resulting authorization. Used by onboarding's Permissions page so the Model-B
/// app-side CoreBluetooth host doesn't surprise-prompt after setup.
final class BluetoothPermissionProbe: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private let onAuthorizationChange: (CBManagerAuthorization) -> Void

    init(onAuthorizationChange: @escaping (CBManagerAuthorization) -> Void) {
        self.onAuthorizationChange = onAuthorizationChange
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onAuthorizationChange(CBCentralManager.authorization)
    }
}
