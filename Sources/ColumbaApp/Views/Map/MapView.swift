//
//  MapView.swift
//  ColumbaApp
//
//  Map tab placeholder view.
//  Will contain network topology and node locations.
//

import SwiftUI

/// Map tab view.
///
/// Placeholder for network map functionality.
@available(iOS 17.0, macOS 14.0, *)
struct MapView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Theme.backgroundPrimary
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.accentColor)

                    Text("Map")
                        .font(.screenTitle)
                        .foregroundStyle(Theme.textPrimary)

                    Text("Network topology will appear here")
                        .font(.bodyText)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding()
            }
            .navigationTitle("Map")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 17.0, macOS 14.0, *)
#Preview {
    MapView()
        .preferredColorScheme(.dark)
}
#endif
