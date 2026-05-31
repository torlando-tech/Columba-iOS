//
//  MainTabView.swift
//  ColumbaApp
//
//  Main navigation container with 4 tabs.
//  Uses TabView with custom styling and SF Symbols.
//

import SwiftUI
import RNSAPI

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
    /// trigger the wizard. Set once by `onAppear` so the persisted flag can be
    /// cleared atomically and subsequent re-appearances don't re-route the user.
    @State private var shouldOpenRNodeWizard: Bool = false
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
        TabView(selection: $selectedTab) {
            // Chats Tab
            ChatsView(
                appServices: appServices,
                messageRepository: messageRepository,
                notificationObserver: notificationObserver
            )
            .tabItem {
                Label(Tab.chats.title, systemImage: Tab.chats.icon)
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
                }
                .tag(Tab.map)
            #endif

            // Settings Tab
            SettingsView(
                appServices: appServices,
                settingsRepository: settingsRepository,
                identityManager: identityManager,
                onIdentitySwitch: onIdentitySwitch,
                shouldOpenRNodeWizard: $shouldOpenRNodeWizard
            )
            .tabItem {
                Label(Tab.settings.title, systemImage: Tab.settings.icon)
            }
            .tag(Tab.settings)
        }
        .tint(Theme.accentColor)
        .onAppear {
            // Consume the persisted flag atomically so a cancelled SettingsView
            // task can't leave the user re-snapped to Settings on every appearance.
            if pendingRNodeSetup {
                selectedTab = .settings
                shouldOpenRNodeWizard = true
                pendingRNodeSetup = false
            }
        }
        .onChange(of: pendingDeepLink) { _, newValue in
            if newValue != nil {
                selectedTab = .contacts
            }
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
}
