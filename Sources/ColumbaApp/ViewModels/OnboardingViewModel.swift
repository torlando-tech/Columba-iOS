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

/// Manages onboarding flow state and persists selections on completion.
@available(iOS 17.0, macOS 14.0, *)
@Observable
@MainActor
final class OnboardingViewModel {
    // MARK: - State

    var currentPage: Int = 0
    var displayName: String = ""
    var selectedInterfaces: Set<OnboardingInterfaceType> = []
    var selectedTcpServer: TcpCommunityServer? = nil
    var notificationsGranted: Bool = false
    var isSaving: Bool = false

    /// Identity created during onboarding (set by prepareIdentity).
    var createdIdentity: LocalIdentity?
    /// QR code string for the created identity.
    var qrCodeString: String = ""

    /// Total number of onboarding pages.
    static let pageCount = 6

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

    // MARK: - Identity Preparation

    /// Create the identity eagerly so the QR code is available on the complete page.
    func prepareIdentity(identityManager: IdentityManager) async {
        guard createdIdentity == nil else { return }
        do {
            let local = try await identityManager.createIdentity(displayName: effectiveDisplayName)
            let identity = try await identityManager.loadIdentityKeys(for: local.identityHash)
            createdIdentity = local

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
        isSaving = true
        defer { isSaving = false }

        // 1. Use existing identity or create one
        let local: LocalIdentity
        if let existing = createdIdentity {
            local = existing
        } else {
            local = try await identityManager.createIdentity(displayName: effectiveDisplayName)
        }
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
        isSaving = true
        defer { isSaving = false }

        let local = try await identityManager.createIdentity(displayName: "Anonymous Peer")
        let _ = try await identityManager.switchToIdentity(local.identityHash)

        await settingsRepository.setDisplayName("Anonymous Peer")

        // Model B: the NE node delivers over the first enabled tcpClient relay, so a
        // skipped setup must still seed one — otherwise the node comes up with no
        // reachable path and the user can't message anyone. (An AutoInterface-only
        // seed is a no-op the NE ignores.)
        let interfaceRepo = InterfaceRepository()
        let server = TcpCommunityServer.defaultServer
        interfaceRepo.addInterface(InterfaceEntity(
            name: server.name,
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(
                targetHost: server.host,
                targetPort: server.port
            ))
        ))

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

    private func createInterfaces(in repo: InterfaceRepository) {
        // Model B: the NE node delivers over the first enabled `tcpClient` relay and
        // IGNORES auto/multipeer/ble entities (those interfaces, where they exist, are
        // owned by the NE process itself, not configured here). So onboarding seeds
        // exactly one enabled TCP relay — the user's pick, or the default community
        // server — guaranteeing a reachable path even if nothing was explicitly chosen.
        let server = selectedTcpServer ?? TcpCommunityServer.defaultServer
        repo.addInterface(InterfaceEntity(
            name: server.name,
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(
                targetHost: server.host,
                targetPort: server.port
            ))
        ))
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
