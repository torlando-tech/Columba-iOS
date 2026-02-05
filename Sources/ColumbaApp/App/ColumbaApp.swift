//
//  ColumbaApp.swift
//  ColumbaApp
//
//  SwiftUI App entry point for Columba iOS.
//  Uses @Observable for state management (iOS 17+).
//

import SwiftUI
import LXMFSwift

/// App Group identifier for shared data between app and extensions.
public let appGroupIdentifier = "group.com.columba.ios"

/// Main SwiftUI App entry point.
///
/// Creates MainTabView as the root navigation container.
/// Configured with dark theme as default.
@main
@available(iOS 17.0, macOS 14.0, *)
struct ColumbaApp: App {
    // MARK: - App State

    /// App-wide state container using @Observable.
    @State private var appState = AppState()

    // MARK: - App Body

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .tint(Theme.accentColor)
        }
    }
}

// MARK: - App State

/// App-wide observable state container.
///
/// Uses iOS 17+ @Observable macro for automatic SwiftUI updates.
@available(iOS 17.0, macOS 14.0, *)
@Observable
final class AppState {
    /// Currently selected tab index.
    var selectedTab: Tab = .chats

    /// Whether the app is fully initialized.
    var isInitialized = false

    /// Error message if initialization fails.
    var initError: String?
}

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
