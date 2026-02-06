//
//  ColumbaApp.swift
//  ColumbaApp
//
//  SwiftUI App entry point for Columba iOS.
//  Initializes services and provides them to the view hierarchy.
//

import SwiftUI
import LXMFSwift
import UserNotifications

/// App Group identifier for shared data between app and extensions.
public let appGroupIdentifier = "group.com.columba.ios"

/// Main SwiftUI App entry point.
///
/// Creates MainTabView as the root navigation container.
/// Handles service initialization via AppServices.
@main
@available(iOS 17.0, macOS 14.0, *)
struct ColumbaApp: App {
    // MARK: - Services

    /// Settings repository for UserDefaults-backed configuration.
    @State private var settingsRepository = SettingsRepository()

    /// Darwin notification observer for IPC from Network Extension.
    @State private var notificationObserver = NotificationObserver()

    // MARK: - App Body

    var body: some Scene {
        WindowGroup {
            RootView(
                settingsRepository: settingsRepository,
                notificationObserver: notificationObserver
            )
            .preferredColorScheme(.dark)
            .tint(Theme.accentColor)
        }
    }
}

// MARK: - Root View

/// Root view that handles async service initialization.
///
/// Separating initialization into a View (vs App) ensures the .task modifier
/// runs correctly in the SwiftUI lifecycle.
@available(iOS 17.0, macOS 14.0, *)
struct RootView: View {
    // MARK: - Dependencies

    let settingsRepository: SettingsRepository
    let notificationObserver: NotificationObserver

    // MARK: - Services

    /// Central service layer owning Identity, Router, Transport, PathTable.
    @State private var appServices = AppServices()

    /// Multi-identity manager.
    @State private var identityManager = IdentityManager()

    // MARK: - Internal State

    @State private var database: LXMFDatabase?
    @State private var messageRepository: MessageRepository?
    @State private var incomingMessageHandler: IncomingMessageHandler?
    @State private var initError: String?
    @State private var isInitialized = false
    @State private var identitySwitchTrigger = UUID()
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Body

    var body: some View {
        Group {
            if let error = initError {
                errorView(error)
            } else if isInitialized,
                      let repo = messageRepository {
                MainTabView(
                    appServices: appServices,
                    messageRepository: repo,
                    settingsRepository: settingsRepository,
                    notificationObserver: notificationObserver,
                    identityManager: identityManager,
                    onIdentitySwitch: {
                        // Reset state so RootView re-initializes
                        isInitialized = false
                        messageRepository = nil
                        incomingMessageHandler = nil
                        database = nil
                        initError = nil
                        identitySwitchTrigger = UUID()
                    }
                )
            } else {
                loadingView
            }
        }
        .task(id: identitySwitchTrigger) {
            await initializeServices()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                NotificationService.shared.clearBadge()
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                // App icon placeholder
                ZStack {
                    Circle()
                        .fill(Theme.accentColor.opacity(0.2))
                        .frame(width: 100, height: 100)

                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accentColor)
                }

                Text("Columba")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.accentColor))
                    .scaleEffect(1.2)

                Text("Connecting to network...")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)

                Text("Connection Failed")
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button {
                    Task {
                        initError = nil
                        await initializeServices()
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: - Initialization

    private func initializeServices() async {
        do {
            // 1. Migration check (first launch after update)
            await identityManager.migrateFromSingleIdentityIfNeeded(settingsRepository: settingsRepository)

            // 2. Get or create active identity
            var activeLocal = await identityManager.getActiveIdentity()
            if activeLocal == nil {
                let newId = try await identityManager.createIdentity(displayName: "Anonymous Peer")
                let (switched, _) = try await identityManager.switchToIdentity(newId.identityHash)
                activeLocal = switched
            }

            guard let active = activeLocal else {
                throw AppServicesError.identityNotInitialized
            }

            // 3. Load identity keys from Keychain
            let identity = try await identityManager.loadIdentityKeys(for: active.identityHash)

            // 4. Load interface configurations
            let interfaceRepo = InterfaceRepository()
            let enabledInterfaces = interfaceRepo.getEnabledInterfaces()

            let serverAddress: String
            if let tcpEntity = enabledInterfaces.first(where: { $0.type == .tcpClient }),
               case .tcpClient(let config) = tcpEntity.config {
                serverAddress = "\(config.targetHost):\(config.targetPort)"
            } else {
                serverAddress = ""
            }

            // 5. Initialize AppServices with identity
            try await appServices.initialize(
                identity: identity,
                identityHash: active.identityHash,
                tcpServerAddress: serverAddress
            )

            // 6. Wire up database, message repo, handler
            guard let db = appServices.database else {
                throw AppServicesError.routerNotInitialized
            }
            self.database = db

            let repo = MessageRepository(database: db)
            self.messageRepository = repo

            let handler = IncomingMessageHandler(messageRepository: repo, database: db)
            self.incomingMessageHandler = handler
            if let router = appServices.router {
                await router.setDelegate(handler)
            }

            // 7. Start AutoInterface if configured (non-blocking)
            if let autoEntity = enabledInterfaces.first(where: { $0.type == .autoInterface }),
               case .autoInterface(let config) = autoEntity.config {
                let groupId = config.groupId ?? "reticulum"
                let services = appServices
                Task {
                    do {
                        try await services.startAutoInterface(groupId: groupId)
                    } catch {
                        // Non-fatal
                    }
                }
            }

            // 8. Request notification permission if enabled
            if UserDefaults.standard.bool(forKey: "notifications_enabled") {
                await NotificationService.shared.requestPermission()
            }

            self.isInitialized = true

        } catch {
            self.initError = error.localizedDescription
        }
    }
}

// MARK: - Tab Enum

/// Tab identifiers for main navigation.
enum Tab: Int, CaseIterable, Identifiable {
    case chats = 0
    case contacts = 1
    case map = 2
    case settings = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .contacts: return "Contacts"
        case .map: return "Map"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .chats: return "bubble.left.fill"
        case .contacts: return "person.2.fill"
        case .map: return "map.fill"
        case .settings: return "gearshape.fill"
        }
    }
}
