//
//  ColumbaApp.swift
//  ColumbaApp
//
//  SwiftUI App entry point for Columba iOS.
//  Initializes services and provides them to the view hierarchy.
//

import SwiftUI
import RNSAPI
import UserNotifications
import SwiftBLEBridge
import os
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

private let logger = Logger(subsystem: "network.columba.Columba", category: "ColumbaApp")

/// Main SwiftUI App entry point.
///
#if os(iOS) && COLUMBA_RUNTIME_PYTHON
@MainActor
private final class BackgroundPropagationCancellation {
    private var operation: Task<Void, Never>?

    func request(_ cancel: @escaping @MainActor @Sendable () async -> Void) {
        guard operation == nil else { return }
        operation = Task { @MainActor in await cancel() }
    }

    func wait() async {
        await operation?.value
    }
}
#endif

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
        #if os(iOS) && COLUMBA_RUNTIME_PYTHON
        // Register before starting embedded Python or any other potentially slow
        // launch work. BGTaskScheduler requires every launch handler to be
        // registered during application launch, including cold background launch.
        BackgroundPropagationRefreshScheduler.register()
        #endif

        #if COLUMBA_RUNTIME_PYTHON
        // Boot embedded CPython once, before anything else can touch it.
        // PythonBridge / PythonRNSBackend depend on this; without it
        // PyGILState_Ensure deadlocks.
        switch PythonRuntime.shared.start() {
        case .success(let version):
            logger.info("Python runtime started: \(version, privacy: .public)")
        case .failure(let err):
            logger.error("Python runtime failed: \(err.localizedDescription, privacy: .public)")
        }
        #endif

        #if os(iOS) && canImport(CoreBluetooth)
        // Track C8 — background BLE wake / CoreBluetooth state restoration.
        // When iOS relaunches the app for a preserved BLE event, CoreBluetooth expects
        // the app to recreate its managers with the same restore identifiers early so
        // it can replay preserved state via `willRestoreState`. This pure-SwiftUI app
        // has no UIApplicationDelegate launch-options hook, so App.init() is the
        // earliest app-owned seam. We restore only when an enabled BLE interface is
        // already persisted; a fresh install must not create CoreBluetooth managers or
        // show a permission prompt before the user explicitly opts into BLE.
        //
        // GAP / FOLLOW-ON: this re-arms the wake and re-adopts CoreBluetooth
        // state, but inbound BLE bytes only become a *delivered + notified*
        // message through the Python delivery path, which requires the active
        // backend to be the Python backend AND its BLE bring-up
        // (startBLEInterface → re-install of SwiftBLEBridge's callbackInvoker) to
        // run on this relaunch. Native-Swift BLE delivery is a deliberate
        // follow-on; until it lands, background-wake delivery is
        // Python-backend-only. See the DELIVERY CAVEAT in SwiftBLEBridge.start().
        //
        // Model B follow-on (now landing): reticulum-swift's `CoreBluetoothBLEDriver`
        // owns CoreBluetooth via `ModelBBLEService` (started from `AppServices` once
        // the identity is ready). It must be the ONLY CB stack — `SwiftBLEBridge`
        // creating its own managers would fight over the same GATT service — so we
        // restore `SwiftBLEBridge` only on the Python-backend (non-Model-B) path.
        // (Model B background-restore via CoreBluetoothBLEDriver's own restore
        // identifier is a further follow-on: it needs the identity at launch.)
        #if COLUMBA_RUNTIME_PYTHON
        // Only re-arm CoreBluetooth restoration after the user has explicitly enabled
        // the shipping BLE interface. Creating these managers on a fresh install causes
        // iOS to prompt before onboarding can explain or offer Bluetooth.
        if InterfaceRepository().getEnabledInterfaces().contains(where: { $0.type == .ble }) {
            SwiftBLEBridge.shared.restoreAtLaunch()
        }
        #elseif COLUMBA_RUNTIME_MODEL_B
        if ModelBRNodeService.rnodeBackgroundRestoreEnabled {
            // GATED (A9, RISK 5): re-materialize the RNode `BLETransport` central early so
            // iOS honors CoreBluetooth state restoration / a background relaunch-for-BLE for
            // a configured RNode. OFF by default — flip `rnodeBackgroundRestoreEnabled`
            // after verifying on a physical device that the background wake is serviced and
            // that the mesh + RNode centrals don't collide on the shared restore identifier.
            ModelBRNodeService.shared.restore()
        }
        #endif
        #endif

        // Install notification delegate early so didReceive (notification tap) works
        UNUserNotificationCenter.current().delegate = NotificationService.delegate

        // Register app-side notification/announce defaults at launch (not lazily on
        // first Settings open) so the foreground notification path isn't suppressed
        // on a fresh install that never visits Settings. (ports #57 dc1024b)
        SettingsViewModel.registerLocalDefaults()
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
                #if DEBUG
                // Test-only deep links — DEBUG builds ONLY. In a release build
                // these would be remote-control backdoors: a crafted
                // lxma://test-call / test-send / test-identity-switch URL could
                // place a call, send a message as the user, or wipe the active
                // identity with no interaction beyond opening the URL. The
                // interop test harness runs DEBUG builds, so it keeps them; the
                // production lxma:// deep-link fall-through (pendingDeepLink,
                // below) stays outside this guard.
                // Test trigger: lxma://test-send?to=HEX&content=...
                // bypasses the UI and directly invokes PythonRNSBackend.sendOpportunistic
                // so external scripts can exercise the Python round-trip during the smoke test.
                if url.host == "test-nomad-fetch" {
                    // lxma://test-nomad-fetch?to=HEX&path=/page/index.mu
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let to = components?.queryItems?.first(where: { $0.name == "to" })?.value ?? ""
                    let path = components?.queryItems?.first(where: { $0.name == "path" })?.value ?? "/page/index.mu"
                    DiagLog.log("[TEST-NOMAD] requested to=\(to) path=\(path)")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestNomadFetch"),
                        object: nil,
                        userInfo: ["to": to, "path": path]
                    )
                    return
                }
                if url.host == "test-answer" {
                    // lxma://test-answer — accept the currently-ringing
                    // incoming call. Sim2 fires this in commit-5 smoke
                    // tests to drive past RINGING → ESTABLISHED so audio
                    // frames start flowing.
                    DiagLog.log("[TEST-ANSWER] triggered")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestAnswer"),
                        object: nil
                    )
                    return
                }
                if url.host == "test-call" {
                    // lxma://test-call?to=HEX[&profile=quality-medium]
                    // Places an outgoing LXST call through CallManager. The
                    // peer must already be in the path table (sim-to-sim
                    // smoke test: bring both sims up, wait for cross-announces,
                    // then fire test-call from sim1 toward sim2's identity hash).
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let to = components?.queryItems?.first(where: { $0.name == "to" })?.value ?? ""
                    let profileRaw = components?.queryItems?.first(where: { $0.name == "profile" })?.value
                    DiagLog.log("[TEST-CALL] to=\(to) profile=\(profileRaw ?? "default")")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestCall"),
                        object: nil,
                        userInfo: ["to": to, "profile": profileRaw ?? ""]
                    )
                    return
                }
                if url.host == "test-link-open" {
                    // lxma://test-link-open?to=HEX&aspect=lxst.telephony
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let to = components?.queryItems?.first(where: { $0.name == "to" })?.value ?? ""
                    let aspect = components?.queryItems?.first(where: { $0.name == "aspect" })?.value ?? "lxst.telephony"
                    DiagLog.log("[TEST-LINK] open to=\(to) aspect=\(aspect)")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestLinkOpen"),
                        object: nil,
                        userInfo: ["to": to, "aspect": aspect]
                    )
                    return
                }
                if url.host == "test-inbound" {
                    // lxma://test-inbound?from=HEX&content=... — synthesizes
                    // a Python-style inbound event so we can exercise the
                    // privacy filter (block_unknown_senders) without
                    // requiring an actual peer.
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let from = components?.queryItems?.first(where: { $0.name == "from" })?.value ?? ""
                    let content = components?.queryItems?.first(where: { $0.name == "content" })?.value ?? "synthetic"
                    DiagLog.log("[TEST-INBOUND] from=\(from) content=\"\(content)\"")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestInbound"),
                        object: nil,
                        userInfo: ["from": from, "content": content]
                    )
                    return
                }
                if url.host == "test-message-status" {
                    // lxma://test-message-status?from=HEX&message=HEX — DEBUG-only
                    // read-after-write probe for physical-device inbound delivery.
                    // Logs existence/count metadata only; never message content.
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let fromHex = components?.queryItems?.first(where: { $0.name == "from" })?.value ?? ""
                    let messageHex = components?.queryItems?.first(where: { $0.name == "message" })?.value ?? ""
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestMessageStatus"),
                        object: nil,
                        userInfo: ["from": fromHex, "message": messageHex]
                    )
                    return
                }
                if url.host == "test-identity-switch" {
                    // lxma://test-identity-switch — creates a fresh identity
                    // and switches to it via the full AppServices.switchIdentity
                    // path so we can verify Python reboots with the new keys.
                    DiagLog.log("[TEST-IDSWITCH] requested")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestIdentitySwitch"),
                        object: nil
                    )
                    return
                }
                if url.host == "test-prop-sync" {
                    // lxma://test-prop-sync?node=HEX
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let node = components?.queryItems?.first(where: { $0.name == "node" })?.value ?? ""
                    DiagLog.log("[TEST-PROP-SYNC] node=\(node)")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestPropSync"),
                        object: nil,
                        userInfo: ["node": node]
                    )
                    return
                }
                if url.host == "test-announce" {
                    // lxma://test-announce?name=...
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let name = components?.queryItems?.first(where: { $0.name == "name" })?.value ?? ""
                    DiagLog.log("[TEST-ANNOUNCE] name=\"\(name)\"")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestAnnounce"),
                        object: nil,
                        userInfo: ["name": name]
                    )
                    return
                }
                if url.host == "test-restart" {
                    DiagLog.log("[TEST-RESTART] requested via URL")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestRestart"),
                        object: nil
                    )
                    return
                }
                if url.host == "test-ble-diagnose" {
                    DiagLog.log("[TEST-BLE-DIAG] requested")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestBLEDiagnose"),
                        object: nil
                    )
                    return
                }
                if url.host == "test-auto-diagnose" {
                    DiagLog.log("[TEST-AUTO-DIAG] requested")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestAutoDiagnose"),
                        object: nil
                    )
                    return
                }
                if url.host == "test-path-table" {
                    DiagLog.log("[TEST-PATH-TABLE] requested")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestPathTable"),
                        object: nil
                    )
                    return
                }
                if url.host == "test-ble-status" {
                    DiagLog.log("[TEST-BLE-STATUS] requested")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestBLEStatus"),
                        object: nil
                    )
                    return
                }
                if url.host == "test-ble-peer-list" {
                    DiagLog.log("[TEST-BLE-PEER-LIST] requested")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestBLEPeerList"),
                        object: nil
                    )
                    return
                }
                if url.host == "test-ble-scan" {
                    // lxma://test-ble-scan?action=start|stop
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let action = components?.queryItems?.first(where: { $0.name == "action" })?.value ?? "start"
                    DiagLog.log("[TEST-BLE-SCAN] action=\(action)")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestBLEScan"),
                        object: nil,
                        userInfo: ["action": action]
                    )
                    return
                }
                if url.host == "test-ble-advertise" {
                    // lxma://test-ble-advertise?action=start|stop[&name=...]
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let action = components?.queryItems?.first(where: { $0.name == "action" })?.value ?? "start"
                    let name = components?.queryItems?.first(where: { $0.name == "name" })?.value ?? ""
                    DiagLog.log("[TEST-BLE-ADVERTISE] action=\(action) name=\(name)")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestBLEAdvertise"),
                        object: nil,
                        userInfo: ["action": action, "name": name]
                    )
                    return
                }
                if url.host == "test-ble-callback-roundtrip" {
                    // lxma://test-ble-callback-roundtrip[?value=N]
                    // Phase 2 smoke test: registers a Python callable that
                    // returns True iff the int arg is even, then invokes it
                    // via the synchronous Swift→Python BLE callback path and
                    // asserts the answer matches. Logs PASS/FAIL to DiagLog.
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let valueStr = components?.queryItems?.first(where: { $0.name == "value" })?.value ?? "4"
                    let value = Int(valueStr) ?? 4
                    DiagLog.log("[TEST-BLE-CB] value=\(value)")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestBLECallback"),
                        object: nil,
                        userInfo: ["value": value]
                    )
                    return
                }
                if url.host == "test-telemetry" {
                    // lxma://test-telemetry?to=HEX[&packed_hex=…&meta_hex=…|&cease=1]
                    //
                    // Drives `backend.telemetry.sendLocationTelemetry` (when
                    // `packed_hex` is supplied) or `sendTelemetryCease`
                    // (when `cease=1`) so the Tests/interop/ harness can pin
                    // the RnsTelemetry seam end-to-end against a Sideband
                    // reference peer without driving the location-sharing UI
                    // (avoids the GPS permission prompt + timing dependence
                    // on a real CLLocationManager fix).
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    func q(_ n: String) -> String? {
                        components?.queryItems?.first(where: { $0.name == n })?.value
                    }
                    let to = q("to") ?? ""
                    let packedHex = q("packed_hex") ?? ""
                    let metaHex = q("meta_hex") ?? ""
                    let cease = (q("cease") ?? "") == "1"
                    DiagLog.log("[TEST-TELEMETRY] to=\(to) packed=\(packedHex.count/2)B meta=\(metaHex.count/2)B cease=\(cease)")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestTelemetry"),
                        object: nil,
                        userInfo: [
                            "to": to,
                            "packed_hex": packedHex,
                            "meta_hex": metaHex,
                            "cease": cease,
                        ]
                    )
                    return
                }
                if url.host == "test-send" {
                    // lxma://test-send?to=HEX&content=…[&method=direct]
                    //   [&image_hex=…&image_format=jpeg]
                    //   [&file_hex=…&file_name=…]
                    //
                    // Bypasses the UI and hands typed send args straight to
                    // `backend.lxmf.sendLxmfMessage(...)` so the
                    // tests/interop/ harness can exercise the full wire path
                    // (LXMF pack + RNS encrypt) without driving the picker
                    // UI. Hex payloads keep the URL stable under iOS's deep-
                    // link length cap for the typical interop fixture (PNG
                    // ≤ a few KB → ≤ 10 KB hex, well under the limit).
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    func q(_ n: String) -> String? {
                        components?.queryItems?.first(where: { $0.name == n })?.value
                    }
                    let to = q("to") ?? ""
                    let content = q("content") ?? ""
                    let method = q("method") ?? ""
                    let imageHex = q("image_hex") ?? ""
                    let imageFormat = q("image_format") ?? ""
                    let fileHex = q("file_hex") ?? ""
                    let fileName = q("file_name") ?? ""
                    logger.info("test-send to=\(to, privacy: .public) content=\(content, privacy: .public)")
                    DiagLog.log("[TEST-SEND] to=\(to) method=\(method.isEmpty ? "opportunistic" : method) content=\"\(content)\" image=\(imageHex.isEmpty ? 0 : imageHex.count/2)B(\(imageFormat)) file=\(fileHex.isEmpty ? 0 : fileHex.count/2)B(\(fileName))")
                    NotificationCenter.default.post(
                        name: Notification.Name("ColumbaTestSend"),
                        object: nil,
                        userInfo: [
                            "to": to,
                            "content": content,
                            "method": method,
                            "image_hex": imageHex,
                            "image_format": imageFormat,
                            "file_hex": fileHex,
                            "file_name": fileName,
                        ]
                    )
                    return
                }
                #endif
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
    #if COLUMBA_RUNTIME_MODEL_B
    @State private var modelBInboundReplay: ModelBInboundReplay?
    #endif
    @State private var initError: String?
    @State private var isInitialized = false
    @State private var serviceInitializationTask: Task<Bool, Never>?
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
        #if DEBUG
        let isScreenshotterLaunch = ProcessInfo.processInfo.arguments.contains("ui-screenshotter")
        #else
        let isScreenshotterLaunch = false
        #endif
        // Maestro clears app state and Keychain before every screenshot. Its
        // explicit DEBUG-only launch argument bypasses the interactive wizard;
        // initializeServices() creates the disposable test identity below.
        self._showOnboarding = State(
            initialValue: !OnboardingViewModel.hasCompletedOnboarding && !isScreenshotterLaunch
        )
    }

    // MARK: - Body

    var body: some View {
        Group {
            if showOnboarding {
                #if COLUMBA_ONBOARDING_ENABLED
                OnboardingView(
                    identityManager: identityManager,
                    settingsRepository: settingsRepository,
                    appServices: appServices,
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
                        #if COLUMBA_RUNTIME_MODEL_B
                        modelBInboundReplay = nil
                        #endif
                        database = nil
                        initError = nil
                        identitySwitchTrigger = UUID()
                    }
                )
                // Voice / CallKit removed in the Python RNS migration (Phase 0).
                // Will return in v2 once canonical Python LXST is ported to iOS audio.
            } else {
                // Not yet initialized. Under Model B, init suspends before the proxy
                // backend starts until the NE/VPN tunnel is up; on first launch that
                // means showing the background-delivery gate instead of an indefinite
                // "Connecting to network…" spinner on a tunnel that doesn't exist yet.
                #if COLUMBA_RUNTIME_MODEL_B
                if appServices.needsBackgroundDeliveryApproval {
                    BackgroundDeliveryGateView(appServices: appServices)
                } else {
                    loadingView
                }
                #else
                loadingView
                #endif
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
                _ = await ensureServicesInitialized()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            let phaseValue = newPhase
            #if os(iOS) && COLUMBA_RUNTIME_PYTHON
            let context = phaseValue == .active
                ? "scene-active"
                : (phaseValue == .background ? "scene-background" : "scene-inactive")
            BackgroundPropagationRefreshScheduler.logRuntime(context: context)
            BackgroundPropagationRefreshScheduler.logPendingRequests(context: context)
            #endif
            if phaseValue == .active {
                if let repository = messageRepository {
                    Task {
                        if let unread = try? await repository.totalUnreadCount() {
                            await NotificationService.shared
                                .synchronizeBadgeWithDurableUnreadCount(unread)
                        }
                    }
                }
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
                #if COLUMBA_RUNTIME_PYTHON
                BackgroundPropagationRefreshScheduler.scheduleFromCurrentSettings()
                #endif
                // Flush RNS's path table + known destinations to disk now —
                // iOS won't run RNS's clean-exit persist, so without this a
                // cold start can't recall previously-heard peers.
                appServices.persistRNSStateOnBackground()
            }
            appServices.locationSharingManager?.setBackgroundState(newPhase != .active)
            #endif
        }
        #if os(iOS) && COLUMBA_RUNTIME_PYTHON
        .task {
            BackgroundRefreshTaskCoordinator.shared.installHandler {
                await performBackgroundPropagationSync()
            }
            BackgroundPropagationRefreshScheduler.scheduleFromCurrentSettings()
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

    #if os(iOS) && COLUMBA_RUNTIME_PYTHON
    // MARK: - Background Propagation Sync

    /// Execute one system-granted refresh against the shipping embedded-Python
    /// propagation path. A cold launch may deliver the task while normal service
    /// initialization is still running, so wait briefly for that single startup
    /// path rather than starting a competing identity/router initialization.
    @MainActor
    private func performBackgroundPropagationSync() async -> Bool {
        BackgroundPropagationRefreshScheduler.logRuntime(context: "workflow-entered")
        DiagLog.log("[BG-SYNC] workflow entered initialized=\(isInitialized)")
        guard await settingsRepository.getPeriodicSyncEnabled() else {
            DiagLog.log("[BG-SYNC] skipped: periodic sync disabled")
            return true
        }

        guard await ensureServicesInitialized() else {
            DiagLog.log("[BG-SYNC] failed: shared service initialization unsuccessful")
            return false
        }

        guard isInitialized,
              let repository = messageRepository,
              let handler = incomingMessageHandler,
              let propagationManager = appServices.propagationManager else {
            DiagLog.log(
                "[BG-SYNC] failed: services not ready initialized=\(isInitialized) "
                    + "repository=\(messageRepository != nil) handler=\(incomingMessageHandler != nil) "
                    + "propagationManager=\(appServices.propagationManager != nil)"
            )
            return false
        }
        DiagLog.log(
            "[BG-SYNC] services ready backend=\(appServices.pythonBackend != nil) "
                + "selectedNode=\(propagationManager.selectedNodeHash != nil)"
        )

        guard await appServices.beginExclusivePythonHostEventProcessing() else {
            DiagLog.log("[BG-SYNC] cancelled before acquiring host event transaction")
            return false
        }
        handler.setUserNotificationsSuppressed(true)

        let syncOperationID = UUID()
        let cancellation = BackgroundPropagationCancellation()
        let workflow = BackgroundPropagationSyncWorkflow<LXMessage>(
            captureInsertionCursor: {
                try await repository.captureMessageInsertionCursor()
            },
            sync: {
                let result = await withTaskCancellationHandler {
                    await propagationManager.syncNow(
                        timeout: 20.0,
                        operationID: syncOperationID
                    )
                } onCancel: {
                    // Promptly interrupt the blocking Python operation. The
                    // structured path below also awaits this same task before the
                    // BG task is reported complete.
                    Task { @MainActor in
                        cancellation.request {
                            await propagationManager.cancelActiveSync(operationID: syncOperationID)
                        }
                    }
                }
                if Task.isCancelled {
                    cancellation.request {
                        await propagationManager.cancelActiveSync(operationID: syncOperationID)
                    }
                    await cancellation.wait()
                    return false
                }
                return result
            },
            messagesInsertedAfter: { cursor in
                try await repository.fetchIncomingMessagesInserted(after: cursor)
            },
            notify: { message in
                await handler.postNotificationForNewlySyncedMessage(message)
            }
        )

        let succeeded = await workflow.run()
        handler.setUserNotificationsSuppressed(false)
        await appServices.endExclusivePythonHostEventProcessing()
        DiagLog.log("[BG-SYNC] completed success=\(succeeded)")
        return succeeded
    }
    #endif

    // MARK: - Initialization

    /// Share one application-lifetime initialization operation between the SwiftUI
    /// scene and a cold-delivered background refresh. This prevents duplicate
    /// Reticulum identities/routers and avoids treating a fixed delay as readiness.
    @MainActor
    private func ensureServicesInitialized() async -> Bool {
        if isInitialized { return true }
        if let serviceInitializationTask {
            return await serviceInitializationTask.value
        }

        let task = Task { @MainActor in
            await initializeServices()
            return isInitialized
        }
        serviceInitializationTask = task
        let succeeded = await task.value
        serviceInitializationTask = nil
        return succeeded
    }

    private func initializeServices() async {
        DiagLog.log("[STARTUP] initializeServices() ENTERED")
        #if os(iOS) && COLUMBA_RUNTIME_PYTHON
        BackgroundPropagationRefreshScheduler.logRuntime(context: "initialize-services")
        BackgroundPropagationRefreshScheduler.logPendingRequests(context: "initialize-services")
        #endif

        #if COLUMBA_RUNTIME_MODEL_B
        // Surface the Network Extension's App-Group diagnostic log into Documents
        // so it's retrievable via `devicectl ... copy from` alongside diag.log.
        // The NE (sandboxed) writes ext-diag.log to the shared container; the host
        // copies the previous background session's log out here on each launch.
        DiagLog.copyExtensionDiagToDocuments()
        #if DEBUG
        // Keep that copy LIVE (not just this launch's snapshot) so on-device NE
        // diagnostics can be tailed in real time. DEBUG-only.
        DiagLog.startExtDiagLiveCopy()
        #endif
        #endif

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
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("ui-screenshotter") {
                    DiagLog.log("[STARTUP] Step 2: creating disposable screenshotter identity")
                    let created = try await identityManager.createIdentity(displayName: "ColumbaSim")
                    let switched = try await identityManager.switchToIdentity(created.identityHash)
                    active = switched.0
                } else {
                    throw AppServicesError.identityNotInitialized
                }
                #else
                throw AppServicesError.identityNotInitialized
                #endif
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

            // Smoke-test escape hatch: when `COLUMBA_TCP_HUB=host:port` is in
            // the environment AND no interfaces are configured yet, inject a
            // TCPClientInterface so a fresh-install build can join the
            // shared hub without manual onboarding. Used by the sim↔iPhone
            // audio-frame test where the iPhone has empty UserDefaults but
            // needs to land on the same RNS network as the sim. The host
            // address is environment-supplied (never committed in source).
            if let hub = ProcessInfo.processInfo.environment["COLUMBA_TCP_HUB"],
               !hub.isEmpty,
               interfaceRepo.getEnabledInterfaces().isEmpty {
                let parts = hub.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2, let port = UInt16(parts[1]) {
                    DiagLog.log("[STARTUP] COLUMBA_TCP_HUB=\(parts[0]):\(port) — seeding TCP interface")
                    interfaceRepo.addInterface(InterfaceEntity(
                        name: "Hub",
                        type: .tcpClient,
                        config: .tcpClient(TCPClientConfig(targetHost: parts[0], targetPort: port))
                    ))
                    UserDefaults.standard.set(true, forKey: "has_completed_onboarding")
                    UserDefaults.standard.set(true, forKey: "settings_initialized")
                } else {
                    DiagLog.log("[STARTUP] COLUMBA_TCP_HUB malformed (\(hub)) — expected host:port")
                }
            }

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

            // 6. Wire up database, message repo, handler.
            // `db` is the RNSAPI Compat store IncomingMessageHandler uses for
            // sender-name lookups. `repo` is the GRDB-backed canonical store
            // (Track A0) the UI reads — built and held by AppServices during
            // initialize(), so reuse that single instance rather than opening a
            // second handle to the same `lxmf-swift.db` (and keeping the
            // LXMFSwift import walled off in MessageRepository.swift).
            guard let db = appServices.database,
                  let repo = appServices.messageRepository else {
                throw AppServicesError.routerNotInitialized
            }
            self.database = db
            self.messageRepository = repo

            #if os(iOS)
            // Initialize the location-sharing manager. iOS-only — the
            // non-iOS Compat stub (RNSAPI/Compat.swift, `#if !os(iOS)`)
            // takes over for cross-platform call sites. Needs `appServices`
            // to reach `backend.telemetry` for sending the periodic updates.
            let locManager = LocationSharingManager(appServices: appServices)
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
            appServices.startPythonEventDrain()

            #if COLUMBA_RUNTIME_MODEL_B
            // Model B: the NE owns LXMF delivery, so the live `LXMRouter` delegate
            // above never fires. Drive the SAME `handler`'s field side-channel
            // processing (reactions / replies / telemetry → map pin / icon / cease)
            // by replaying NE-persisted inbound messages from the shared store on
            // each Darwin "new message" ping. See `ModelBInboundReplay`.
            let replay = ModelBInboundReplay(
                repository: repo,
                handler: handler,
                identityScope: appServices.grdbDatabasePath ?? ""
            )
            self.modelBInboundReplay = replay
            replay.start()
            #endif

            // 7. Start all enabled interfaces (non-blocking)
            DiagLog.log("[STARTUP] Step 7: starting \(enabledInterfaces.count) enabled interfaces")
            let services = appServices
            for iface in enabledInterfaces {
                DiagLog.log("[STARTUP] Starting interface: \(iface.type) name=\(iface.name)")
                switch iface.type {
                case .tcpClient:
                    if BackendPreference.modelB {
                        // Model B: the NE owns the single TCP relay interface. The app
                        // must NOT open a competing/duplicate one — doing so spawns a
                        // second socket to the relay and surfaces as a stray
                        // "enabled but disconnected" interface in the UI. The app owns
                        // only Auto/BLE/RNode in Model B; their frames bridge to the NE.
                        DiagLog.log("[STARTUP] Model B: skipping app-side TCP interface (NE owns TCP)")
                    } else if case .tcpClient(let config) = iface.config {
                        let entityId = iface.id
                        Task {
                            DiagLog.log("[STARTUP] TCP interface \(config.targetHost):\(config.targetPort) — registering")
                            do {
                                try await services.connectTCPInterface(entityId: entityId, host: config.targetHost, port: config.targetPort)
                                // NB: this only means the interface was added and a
                                // connection was initiated — NOT that the socket is up.
                                // The Swift backend's connect() is fire-and-forget; the
                                // real connected/connecting state shows in the `[RNS] iface
                                // … -> connected/connecting` poll lines.
                                DiagLog.log("[STARTUP] TCP interface registered [\(entityId)] (connecting async — see [RNS] iface state)")
                            } catch {
                                DiagLog.log("[STARTUP] TCP interface add FAILED [\(entityId)]: \(error.localizedDescription)")
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

            // 8. Request notification permission WITHOUT blocking init. A blocking
            // `await` here holds the rest of RootView setup (and `isInitialized`)
            // hostage behind the OS auth sheet until the user taps Allow/Don't Allow
            // — and on a fresh-install device the smoke harness (no UI driver) can't
            // tap it at all, so init never completes. The foreground UN delegate is
            // already installed eagerly in `init()` (see the delegate assignment in
            // ColumbaApp.init), so deferring the prompt is safe. (ports #57 fc9b0b8)
            Task { _ = await NotificationService.shared.requestPermission() }

            self.isInitialized = true

            #if os(iOS) && COLUMBA_RUNTIME_PYTHON
            // Submit after startup as well as on scene/settings transitions. This
            // survives the startup diagnostic-log reset and ensures the first
            // request is based on fully restored persisted settings.
            BackgroundPropagationRefreshScheduler.scheduleFromCurrentSettings()
            #endif

            // DEBUG: Auto-trigger propagation sync on launch for testing
            if ProcessInfo.processInfo.arguments.contains("--auto-sync") {
                let services = appServices
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await services.propagationManager?.syncNow()
                }
            }

            #if os(iOS)
            // Smoke-test escape hatch: `COLUMBA_AUTO_CALL_TO=<hex>` places an
            // outgoing LXST call once the target destination shows up in the
            // path table. Used in sim↔iPhone reverse-direction audio testing
            // where the iPhone needs to be the caller and we can't push URL
            // events to a real device (`simctl openurl` is simulator-only,
            // `devicectl` has no URL-open subcommand). Polls the path table
            // for up to 60s.
            if let targetHex = ProcessInfo.processInfo.environment["COLUMBA_AUTO_CALL_TO"],
               !targetHex.isEmpty,
               let targetHash = try? targetHex.hexToData() {
                let services = appServices
                Task { @MainActor in
                    DiagLog.log("[AUTO_CALL] waiting for \(targetHex.prefix(8)) in path table")
                    var attempts = 0
                    while attempts < 30 {
                        if let pt = services.pathTable,
                           await pt.lookup(destinationHash: targetHash) != nil {
                            DiagLog.log("[AUTO_CALL] target found after \(attempts * 2)s — placing call")
                            services.callManager?.initiateCall(
                                destinationHash: targetHash,
                                profile: .qualityMedium,
                                peerDisplayName: nil
                            )
                            return
                        }
                        try? await Task.sleep(for: .seconds(2))
                        attempts += 1
                    }
                    DiagLog.log("[AUTO_CALL] timed out waiting for \(targetHex.prefix(8))")
                }
            }
            #endif

        } catch {
            DiagLog.log("[STARTUP] _initializeServicesOnce FAILED: \(error)")
            throw error
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
