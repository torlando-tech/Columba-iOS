//
//  ColumbaApp.swift
//  ColumbaApp
//
//  SwiftUI App entry point for Columba iOS.
//  Initializes services and provides them to the view hierarchy.
//

import SwiftUI
import UserNotifications
import BackgroundTasks
import os

private let logger = Logger(subsystem: "network.columba.Columba", category: "ColumbaApp")

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

    /// Pending lxma:// deep link URL to process.
    @State private var pendingDeepLink: String?

    // MARK: - Init

    init() {
        // Boot embedded CPython once, before anything else can touch it.
        // PythonBridge / PythonRNSBackend depend on this; without it
        // PyGILState_Ensure deadlocks.
        switch PythonRuntime.shared.start() {
        case .success(let version):
            logger.info("Python runtime started: \(version, privacy: .public)")
        case .failure(let err):
            logger.error("Python runtime failed: \(err.localizedDescription, privacy: .public)")
        }

        #if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "network.columba.Columba.sync",
            using: nil
        ) { task in
            NotificationCenter.default.post(name: .columbaBackgroundSync, object: task)
        }
        #endif

        // Install notification delegate early so didReceive (notification tap) works
        UNUserNotificationCenter.current().delegate = NotificationService.delegate
    }

    // MARK: - App Body

    var body: some Scene {
        WindowGroup {
            RootView(
                settingsRepository: settingsRepository,
                notificationObserver: notificationObserver,
                pendingDeepLink: $pendingDeepLink
            )
            #if os(iOS)
            .background(KeyboardDismissHelper())
            #endif
            .preferredColorScheme(ThemeManager.shared.resolvedColorScheme)
            .tint(Theme.accentColor)
            .id(ThemeManager.shared.themeVersion)
            .onOpenURL { url in
                guard url.scheme == "lxma" else { return }
                // Test trigger: lxma://test-send?to=HEX&content=...
                // bypasses the UI and directly invokes PythonRNSBackend.sendOpportunistic
                // so external scripts can exercise the Python round-trip during the smoke test.
                if url.host == "test-send" {
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let to = components?.queryItems?.first(where: { $0.name == "to" })?.value ?? ""
                    let content = components?.queryItems?.first(where: { $0.name == "content" })?.value ?? ""
                    logger.info("test-send to=\(to, privacy: .public) content=\(content, privacy: .public)")
                    DiagLog.log("[TEST-SEND] to=\(to) content=\(content)")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestSend"),
                        object: nil,
                        userInfo: ["to": to, "content": content]
                    )
                    return
                }
                pendingDeepLink = url.absoluteString
            }
        }
    }
}

#if os(iOS)
// MARK: - Keyboard Dismiss Helper

/// Installs a UITapGestureRecognizer on the window that dismisses the keyboard
/// when tapping outside text fields. Uses `cancelsTouchesInView = false` so
/// buttons, nav bar items, and other controls continue to work normally.
private struct KeyboardDismissHelper: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false // Don't block any touches on this view

        DispatchQueue.main.async {
            guard let window = view.window else { return }

            let tapGesture = UITapGestureRecognizer(target: window, action: #selector(UIView.endEditing(_:)))
            tapGesture.requiresExclusiveTouchType = false
            tapGesture.cancelsTouchesInView = false
            window.addGestureRecognizer(tapGesture)
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

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
    @Binding var pendingDeepLink: String?

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
    @State private var showOnboarding: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    init(settingsRepository: SettingsRepository, notificationObserver: NotificationObserver, pendingDeepLink: Binding<String?>) {
        self.settingsRepository = settingsRepository
        self.notificationObserver = notificationObserver
        self._pendingDeepLink = pendingDeepLink
        // Migrate existing users so they skip onboarding
        OnboardingViewModel.migrateExistingUsers()
        self._showOnboarding = State(initialValue: !OnboardingViewModel.hasCompletedOnboarding)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if showOnboarding {
                #if COLUMBA_ONBOARDING_ENABLED
                OnboardingView(
                    identityManager: identityManager,
                    settingsRepository: settingsRepository,
                    onComplete: {
                        showOnboarding = false
                        identitySwitchTrigger = UUID()
                    }
                )
                #else
                // Onboarding flow disabled in this build — bypass straight to main UI.
                Color.clear.onAppear { showOnboarding = false }
                #endif
            } else if let error = initError {
                errorView(error)
            } else if isInitialized,
                      let repo = messageRepository {
                MainTabView(
                    appServices: appServices,
                    messageRepository: repo,
                    settingsRepository: settingsRepository,
                    notificationObserver: notificationObserver,
                    identityManager: identityManager,
                    pendingDeepLink: $pendingDeepLink,
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
                // Voice / CallKit removed in the Python RNS migration (Phase 0).
                // Will return in v2 once canonical Python LXST is ported to iOS audio.
            } else {
                loadingView
            }
        }
        .onChange(of: colorScheme) { _, newScheme in
            ThemeManager.shared.systemColorScheme = newScheme
        }
        .onAppear {
            ThemeManager.shared.systemColorScheme = colorScheme
        }
        .task(id: identitySwitchTrigger) {
            if !showOnboarding {
                await initializeServices()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            let phaseValue = newPhase
            if phaseValue == .active {
                NotificationService.shared.clearBadge()
                // Sync from propagation node when app becomes active,
                // debounced to avoid rapid re-syncs on quick app switches
                if let propManager = appServices.propagationManager,
                   !propManager.isSyncing {
                    let lastSync = propManager.lastSyncTime ?? .distantPast
                    if Date().timeIntervalSince(lastSync) > 60 {
                        Task { await propManager.syncNow() }
                    }
                }
            }
            #if os(iOS)
            if newPhase == .background {
                scheduleBackgroundSync()
            }
            appServices.locationSharingManager?.setBackgroundState(newPhase != .active)
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .columbaBackgroundSync)) { note in
            guard let task = note.object as? BGAppRefreshTask else { return }
            handleBackgroundSync(task: task)
        }
        #endif
    }

    // MARK: - Loading View

    private var loadingView: some View {
        ZStack {
            Theme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 20) {
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
                    .foregroundStyle(Theme.textPrimary)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.accentColor))
                    .scaleEffect(1.2)

                Text("Connecting to network...")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        ZStack {
            Theme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)

                Text("Connection Failed")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
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

    #if os(iOS)
    // MARK: - Background Sync

    private func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: "network.columba.Columba.sync")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundSync(task: BGAppRefreshTask) {
        scheduleBackgroundSync() // always reschedule first
        let syncTask = Task {
            await appServices.propagationManager?.syncNow()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            syncTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
    #endif

    // MARK: - Initialization

    private func initializeServices() async {
        DiagLog.log("[STARTUP] initializeServices() ENTERED")

        // Retry the entire init up to 5 times with increasing delay —
        // the Keychain, file system, or CryptoKit may not be ready
        // immediately after device unlock.
        var lastError: Error?
        for attempt in 1...5 {
            do {
                try await _initializeServicesOnce()
                if attempt > 1 {
                    DiagLog.log("[STARTUP] Succeeded on attempt \(attempt)")
                }
                return // success
            } catch {
                lastError = error
                DiagLog.log("[STARTUP] Attempt \(attempt)/5 failed: \(error)")
                if attempt < 5 {
                    let delay = Double(attempt) // 1s, 2s, 3s, 4s
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        self.initError = lastError?.localizedDescription ?? "Unknown error"
    }

    private func _initializeServicesOnce() async throws {
        do {
            // 1. Migration check (first launch after update)
            DiagLog.log("[STARTUP] Step 1: migration check")
            await identityManager.migrateFromSingleIdentityIfNeeded(settingsRepository: settingsRepository)

            // 2. Get active identity (created during onboarding, or auto-create
            // one when onboarding is compile-guarded off — needed so the
            // Python-RNS smoke test can run without UI taps).
            DiagLog.log("[STARTUP] Step 2: get active identity")
            let active: LocalIdentity
            if let existing = await identityManager.getActiveIdentity() {
                active = existing
            } else {
                #if COLUMBA_ONBOARDING_ENABLED
                throw AppServicesError.identityNotInitialized
                #else
                DiagLog.log("[STARTUP] Step 2: no identity — auto-creating for smoke test")
                let created = try await identityManager.createIdentity(displayName: "ColumbaSim")
                let switched = try await identityManager.switchToIdentity(created.identityHash)
                active = switched.0
                #endif
            }

            // 3. Load identity keys from Keychain
            DiagLog.log("[STARTUP] Step 3: load identity keys for \(active.identityHash)")
            let identity = try await identityManager.loadIdentityKeys(for: active.identityHash)
            DiagLog.log("[STARTUP] Step 3: identity loaded OK")

            // 4. Load interface configurations
            let interfaceRepo = InterfaceRepository()
            let enabledInterfaces = interfaceRepo.getEnabledInterfaces()
            DiagLog.log("[STARTUP] Step 4: \(enabledInterfaces.count) enabled interfaces")

            // 5. Initialize AppServices with identity. The Python RNS stack
            //    builds its config file from InterfaceRepository's enabled
            //    interfaces (PythonConfigWriter); when the list is empty the
            //    app comes up offline and the user adds an interface via
            //    Settings → Manage Interfaces.
            DiagLog.log("[STARTUP] Step 5: initialize AppServices")
            try await appServices.initialize(
                identity: identity,
                identityHash: active.identityHash,
                tcpServerAddress: ""
            )
            DiagLog.log("[STARTUP] Step 5: AppServices initialized OK")

            // 6. Wire up database, message repo, handler
            guard let db = appServices.database else {
                throw AppServicesError.routerNotInitialized
            }
            self.database = db

            let repo = MessageRepository(database: db)
            self.messageRepository = repo

            #if os(iOS)
            // Initialize location sharing manager (stub when COLUMBA_LOCATION_ENABLED off)
            let locManager = LocationSharingManager()
            appServices.locationSharingManager = locManager
            let handler = IncomingMessageHandler(messageRepository: repo, database: db, locationSharingManager: locManager)
            #else
            let handler = IncomingMessageHandler(messageRepository: repo, database: db)
            #endif
            handler.pathTable = appServices.pathTable
            self.incomingMessageHandler = handler
            if let router = appServices.router {
                await router.setDelegate(handler)
            }

            // 7. Start all enabled interfaces (non-blocking)
            DiagLog.log("[STARTUP] Step 7: starting \(enabledInterfaces.count) enabled interfaces")
            let services = appServices
            for iface in enabledInterfaces {
                DiagLog.log("[STARTUP] Starting interface: \(iface.type) name=\(iface.name)")
                switch iface.type {
                case .tcpClient:
                    if case .tcpClient(let config) = iface.config {
                        let entityId = iface.id
                        Task {
                            DiagLog.log("[STARTUP] TCP connecting: \(config.targetHost):\(config.targetPort)")
                            do {
                                try await services.connectTCPInterface(entityId: entityId, host: config.targetHost, port: config.targetPort)
                                DiagLog.log("[STARTUP] TCP connected: \(entityId)")
                            } catch {
                                DiagLog.log("[STARTUP] TCP connect FAILED [\(entityId)]: \(error.localizedDescription)")
                            }
                        }
                    }
                case .tcpServer:
                    break
                case .autoInterface:
                    if case .autoInterface(let config) = iface.config {
                        let groupId = config.groupId ?? "reticulum"
                        Task {
                            DiagLog.log("[STARTUP] AutoInterface starting, groupId=\(groupId)")
                            try? await services.startAutoInterface(groupId: groupId)
                            DiagLog.log("[STARTUP] AutoInterface started")
                        }
                    }
                case .ble:
                    #if canImport(CoreBluetooth)
                    Task {
                        try? await services.startBLEInterface()
                    }
                    #endif
                case .rnode:
                    if case .rnode(let config) = iface.config {
                        DiagLog.log("[STARTUP] Starting RNode: device=\(config.deviceName), freq=\(config.frequency)")
                        Task {
                            do {
                                try await services.startRNodeInterface(
                                    config: config,
                                    name: iface.name
                                )
                                DiagLog.log("[STARTUP] RNode started successfully")
                            } catch {
                                DiagLog.log("[STARTUP] RNode start FAILED: \(error.localizedDescription)")
                            }
                        }
                    } else {
                        DiagLog.log("[STARTUP] RNode interface has no config!")
                    }
                case .multipeer:
                    #if canImport(MultipeerConnectivity)
                    Task {
                        DiagLog.log("[STARTUP] Starting Multipeer Connectivity")
                        do {
                            try await services.startMPCInterface()
                            DiagLog.log("[STARTUP] Multipeer started successfully")
                        } catch {
                            DiagLog.log("[STARTUP] Multipeer FAILED: \(error)")
                        }
                    }
                    #endif
                }
            }

            // 8. Request notification permission and install foreground delegate
            await NotificationService.shared.requestPermission()

            self.isInitialized = true

            // DEBUG: Auto-trigger propagation sync on launch for testing
            if ProcessInfo.processInfo.arguments.contains("--auto-sync") {
                let services = appServices
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await services.propagationManager?.syncNow()
                }
            }

        } catch {
            DiagLog.log("[STARTUP] _initializeServicesOnce FAILED: \(error)")
            throw error
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let columbaBackgroundSync = Notification.Name("network.columba.Columba.backgroundSync")
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
