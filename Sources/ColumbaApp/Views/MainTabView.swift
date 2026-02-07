//
//  MainTabView.swift
//  ColumbaApp
//
//  Main navigation container with 4 tabs.
//  Uses TabView with custom styling and SF Symbols.
//

import SwiftUI
import LXMFSwift

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
    var onIdentitySwitch: (() -> Void)?

    // MARK: - State

    @State private var selectedTab: Tab = .chats

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
                messageRepository: messageRepository
            )
            .tabItem {
                Label(Tab.contacts.title, systemImage: Tab.contacts.icon)
            }
            .tag(Tab.contacts)

            // Map Tab
            MapView()
                .tabItem {
                    Label(Tab.map.title, systemImage: Tab.map.icon)
                }
                .tag(Tab.map)

            // Settings Tab
            SettingsView(
                appServices: appServices,
                settingsRepository: settingsRepository,
                identityManager: identityManager,
                onIdentitySwitch: onIdentitySwitch
            )
            .tabItem {
                Label(Tab.settings.title, systemImage: Tab.settings.icon)
            }
            .tag(Tab.settings)
        }
        .tint(Theme.accentColor)
    }
}
