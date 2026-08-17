//
//  MainTabView.swift
//  ColumbaApp
//
//  Main navigation container with 4 tabs.
//  Uses TabView with custom styling and SF Symbols.
//

import SwiftUI
import RNSAPI

struct InterfaceConnectivityBannerContent: Equatable {
    let title: String
    let actionTitle: String

    static func forConnectionState(isConnected: Bool) -> Self? {
        guard !isConnected else { return nil }
        return Self(
            title: String(localized: "No Interfaces Connected"),
            actionTitle: String(localized: "Manage")
        )
    }
}

private struct InterfaceConnectivityBanner: View {
    let content: InterfaceConnectivityBannerContent
    let onManageInterfaces: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onManageInterfaces) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)

                    Text(content.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer(minLength: 8)

                    Text(content.actionTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accentColor)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accentColor)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens network interface settings")
            .accessibilityIdentifier("interface_connectivity_banner")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 0)
        .background(Theme.warning.opacity(0.14))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Main tab-based navigation container.
///
/// Provides navigation between:
/// - Chats: Conversation list and messaging
/// - Contacts: Address book and announcements
/// - Map: Vector map display
/// - Settings: App configuration
@available(iOS 17.0, macOS 14.0, *)
struct MainTabView: View {
    // MARK: - Dependencies

    let appServices: AppServices
    let messageRepository: MessageRepository
    let settingsRepository: SettingsRepository
    let notificationObserver: NotificationObserver
    let identityManager: IdentityManager
    @Binding var pendingDeepLink: String?
    var onIdentitySwitch: (() -> Void)?

    // MARK: - State

    @State private var selectedTab: Tab = .chats
    @AppStorage("map_http_enabled") private var mapHttpEnabled: Bool = true
    @AppStorage(OnboardingViewModel.pendingRNodeSetupKey) private var pendingRNodeSetup: Bool = false
    /// Session-scoped copy of `pendingRNodeSetup` consumed by `SettingsView` to
    /// trigger the wizard. The request may exist before MainTabView appears or
    /// arrive later when onboarding completes over an already-mounted tab view.
    @State private var shouldOpenRNodeWizard: Bool = false
    /// Session-scoped route request raised by the disconnected-interface banner.
    /// Settings consumes it after its navigation stack and interface model exist.
    @State private var shouldOpenInterfaceManagement: Bool = false
    /// Which app-root voice-call cover (if any) is showing, driven off
    /// callManager.callState so a call's UI shows from any tab and survives
    /// navigating away from the chat. A single optional makes the two covers
    /// mutually exclusive in the type system (vs. two independent bools that
    /// could, in principle, both be true for a render cycle).
    private enum CallCover: Identifiable {
        case incoming, active
        var id: Self { self }
    }
    @State private var activeCallCover: CallCover?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // The shipping runtime owns the aggregate TCP/Auto/RNode/BLE state.
            // Model B's relay lives in the Network Extension and is not represented
            // by AppServices.isConnected, so do not present a false offline banner there.
            #if COLUMBA_RUNTIME_PYTHON
            if let content = InterfaceConnectivityBannerContent.forConnectionState(
                isConnected: appServices.isConnected
            ) {
                InterfaceConnectivityBanner(content: content) {
                    selectedTab = .settings
                    shouldOpenInterfaceManagement = true
                }
            }
            #endif

            TabView(selection: $selectedTab) {
            // Chats Tab
            ChatsView(
                appServices: appServices,
                messageRepository: messageRepository,
                notificationObserver: notificationObserver
            )
            .tabItem {
                Label(Tab.chats.title, systemImage: Tab.chats.icon)
                    .accessibilityIdentifier("tab_chats")
            }
            .tag(Tab.chats)

            // Contacts Tab
            ContactsView(
                appServices: appServices,
                messageRepository: messageRepository,
                pendingDeepLink: $pendingDeepLink
            )
            .tabItem {
                Label(Tab.contacts.title, systemImage: Tab.contacts.icon)
                    .accessibilityIdentifier("tab_contacts")
            }
            .tag(Tab.contacts)

            #if os(iOS)
            // Map Tab
            MapView(
                appServices: appServices,
                mapHttpEnabled: mapHttpEnabled
            )
                .tabItem {
                    Label(Tab.map.title, systemImage: Tab.map.icon)
                        .accessibilityIdentifier("tab_map")
                }
                .tag(Tab.map)
            #endif

            // Settings Tab
            SettingsView(
                appServices: appServices,
                settingsRepository: settingsRepository,
                identityManager: identityManager,
                onIdentitySwitch: onIdentitySwitch,
                shouldOpenRNodeWizard: $shouldOpenRNodeWizard,
                shouldOpenInterfaceManagement: $shouldOpenInterfaceManagement
            )
            .tabItem {
                Label(Tab.settings.title, systemImage: Tab.settings.icon)
                    .accessibilityIdentifier("tab_settings")
            }
            .tag(Tab.settings)
            }
        }
        .tint(Theme.accentColor)
        .onAppear {
            consumePendingRNodeSetup()
            routePendingDeepLink()
        }
        .onChange(of: pendingRNodeSetup) { _, requested in
            // MainTabView can already be mounted behind onboarding, in which case
            // its onAppear ran before completeOnboarding persisted this request.
            if requested {
                consumePendingRNodeSetup()
            }
        }
        .onChange(of: pendingDeepLink) { _, _ in
            routePendingDeepLink()
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if NotificationService.pendingConversationHash != nil {
                selectedTab = .chats
            }
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if NotificationService.pendingConversationHash != nil {
                selectedTab = .chats
            }
        }
        #endif
        // Reading callState/isIncoming in these onChange `of:` values registers
        // them as @Observable dependencies, so body re-evaluates and the covers
        // react when a call rings / connects / ends.
        .onChange(of: appServices.callManager?.callState) { _, _ in refreshCallPresentation() }
        .onChange(of: appServices.callManager?.isIncoming) { _, _ in refreshCallPresentation() }
        #if os(iOS)
        // Single cover driven by the optional enum — .incoming shows the
        // pre-answer in-app answer/decline UI (alongside CallKit); .active is
        // the in-app call UI for an outgoing/answered call's duration.
        .fullScreenCover(item: $activeCallCover) { cover in
            if let cm = appServices.callManager {
                switch cover {
                case .incoming:
                    IncomingCallScreen(callManager: cm, onAnswer: {})
                case .active:
                    VoiceCallScreen(
                        callManager: cm,
                        peerName: cm.peerName ?? "Unknown",
                        destinationHash: cm.peerHash.flatMap { try? $0.hexToData() } ?? Data()
                    )
                    .onAppear {
                        // An active call should always carry a decodable peerHash.
                        // Keep the empty-Data() fallback so the call UI never
                        // crashes, but surface the violation instead of masking
                        // it silently (the previous behavior).
                        if (cm.peerHash.flatMap { try? $0.hexToData() }) == nil {
                            DiagLog.log("[CALL] VoiceCallScreen shown without a decodable peerHash (peerHash=\(cm.peerHash ?? "nil")) — CallManager state invariant violation; using empty destination hash")
                        }
                    }
                }
            } else {
                // callManager went nil between setting the cover and this body
                // (refreshCallPresentation clears it via onChange a tick later);
                // self-dismiss now so we never flash an empty full-screen view.
                Color.clear.onAppear { activeCallCover = nil }
            }
        }
        #endif
    }

    /// Recompute which voice-call cover should show from callManager state:
    /// IncomingCallScreen while an incoming call rings (pre-answer),
    /// VoiceCallScreen for everything else non-idle (outgoing + answered +
    /// the brief "ended" state).
    private func refreshCallPresentation() {
        guard let cm = appServices.callManager else {
            activeCallCover = nil
            return
        }
        switch cm.callState {
        case .idle:
            activeCallCover = nil
        case .connecting, .ringing:
            // Pre-answer window. An incoming call shows the answer/decline UI
            // for its *whole* pre-answer lifecycle (.connecting → .ringing) —
            // never VoiceCallScreen, which inits audio/CallKit and could race
            // the answer/decline actions. The decision rides on isIncoming
            // alone (CallManager.prepareForIncomingCall sets it before any
            // callState transition), so the cover can't depend on the order in
            // which callState/isIncoming are observed, and a late .ringing
            // can't flash .active first. Outgoing pre-answer (dialing) → in-call UI.
            activeCallCover = cm.isIncoming ? .incoming : .active
        default:
            // calling / established / busy / ended → in-call UI.
            activeCallCover = .active
        }
    }

    /// Atomically route an onboarding RNode request into Settings and hand the
    /// wizard trigger to its stable InterfaceManagementViewModel.
    private func consumePendingRNodeSetup() {
        guard pendingRNodeSetup else { return }
        selectedTab = .settings
        shouldOpenRNodeWizard = true
        pendingRNodeSetup = false
    }

    /// Route both cold-start and already-mounted LXMA URLs to Contacts.
    /// `onChange` alone misses a value that exists before this view mounts.
    private func routePendingDeepLink() {
        if pendingDeepLink != nil {
            selectedTab = .contacts
        }
    }
}
