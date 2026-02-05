//
//  MainTabView.swift
//  ColumbaApp
//
//  Main navigation container with 4 tabs.
//  Uses TabView with custom styling and SF Symbols.
//

import SwiftUI

/// Main tab-based navigation container.
///
/// Provides navigation between:
/// - Chats: Conversation list and messaging
/// - Contacts: Address book and announcements
/// - Map: Network topology and node locations
/// - Settings: App configuration
@available(iOS 17.0, macOS 14.0, *)
struct MainTabView: View {
    // MARK: - Environment

    @Environment(AppState.self) private var appState

    // MARK: - Body

    var body: some View {
        @Bindable var state = appState

        TabView(selection: $state.selectedTab) {
            // Chats Tab
            ChatsView()
                .tabItem {
                    Label(Tab.chats.title, systemImage: Tab.chats.icon)
                }
                .tag(Tab.chats)

            // Contacts Tab
            ContactsView()
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
            SettingsView()
                .tabItem {
                    Label(Tab.settings.title, systemImage: Tab.settings.icon)
                }
                .tag(Tab.settings)
        }
        .tint(Theme.accentColor)
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 17.0, macOS 14.0, *)
#Preview {
    MainTabView()
        .environment(AppState())
        .preferredColorScheme(.dark)
}
#endif
