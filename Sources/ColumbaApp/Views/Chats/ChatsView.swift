//
//  ChatsView.swift
//  Columba-iOS
//
//  Main chats view displaying the list of conversations.
//  Features dark theme, glass card styling, and smooth animations.
//

import SwiftUI

/// Main chats view displaying conversation list.
///
/// Features:
/// - NavigationStack with "Chats" title and conversation count subtitle
/// - Search and refresh toolbar buttons
/// - List of ConversationRow items with glass card backgrounds
/// - Empty state when no conversations exist
/// - Pull-to-refresh support
struct ChatsView: View {
    // MARK: - State

    /// ViewModel managing conversation data.
    @State private var viewModel = ChatsViewModel()

    /// Controls search sheet presentation.
    @State private var isSearchPresented: Bool = false

    /// Controls the search text field focus.
    @FocusState private var isSearchFocused: Bool

    // MARK: - Theme Colors

    private let backgroundColor = Color.black
    private let accentColor = Color(red: 0.404, green: 0.314, blue: 0.643) // #6750A4

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                backgroundColor.ignoresSafeArea()

                // Content
                if viewModel.filteredConversations.isEmpty && !viewModel.isLoading {
                    emptyStateView
                } else {
                    conversationListView
                }

                // Loading overlay
                if viewModel.isLoading {
                    loadingOverlay
                }
            }
            .navigationTitle("Chats")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(backgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Empty to allow custom title area
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Search button
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearchPresented.toggle()
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                    }

                    // Refresh button
                    Button {
                        Task {
                            await viewModel.refreshConversations()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                            .rotationEffect(.degrees(viewModel.isRefreshing ? 360 : 0))
                            .animation(
                                viewModel.isRefreshing
                                    ? .linear(duration: 1).repeatForever(autoreverses: false)
                                    : .default,
                                value: viewModel.isRefreshing
                            )
                    }
                    .disabled(viewModel.isRefreshing)
                }
            }
            #endif
            .safeAreaInset(edge: .top) {
                headerView
            }
        }
        .preferredColorScheme(.dark)
        .tint(accentColor)
        .task {
            await viewModel.loadConversations()
        }
    }

    // MARK: - Subviews

    /// Custom header with subtitle showing conversation count.
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar (when active)
            if isSearchPresented {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Search bar for filtering conversations.
    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.5))

                TextField("Search conversations", text: $viewModel.searchQuery)
                    .foregroundColor(.white)
                    .focused($isSearchFocused)
                    .submitLabel(.search)

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button("Cancel") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.searchQuery = ""
                    isSearchPresented = false
                    isSearchFocused = false
                }
            }
            .foregroundColor(accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear {
            isSearchFocused = true
        }
    }

    /// Subtitle showing conversation count.
    private var subtitleView: some View {
        Text(viewModel.conversationCountText)
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    /// List of conversation rows.
    private var conversationListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                // Subtitle
                HStack {
                    Text(viewModel.conversationCountText)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)

                // Conversation rows
                ForEach(viewModel.filteredConversations) { conversation in
                    NavigationLink(value: conversation) {
                        ConversationRow(
                            conversation: conversation,
                            onFavoriteToggle: {
                                viewModel.toggleFavorite(conversation)
                            }
                        )
                    }
                    .buttonStyle(ConversationRowButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .refreshable {
            await viewModel.refreshConversations()
        }
        .navigationDestination(for: Conversation.self) { conversation in
            // Placeholder for message thread view
            Text("Chat with \(conversation.peerName)")
                .foregroundColor(.white)
        }
    }

    /// Empty state view when no conversations exist.
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            // Icon
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.15))
                    .frame(width: 100, height: 100)

                Image(systemName: "envelope.open")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(accentColor)
            }

            // Title
            Text("No Conversations Yet")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)

            // Description
            Text("Share your Reticulum address with others to start receiving encrypted messages.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)

            // Refresh button
            Button {
                Task {
                    await viewModel.refreshConversations()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 8)
        }
        .padding()
    }

    /// Loading overlay with progress indicator.
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)

            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: accentColor))
                .scaleEffect(1.2)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Button Style

/// Custom button style for conversation rows with press animation.
struct ConversationRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("With Conversations") {
    ChatsView()
}

#Preview("Empty State") {
    let view = ChatsView()
    // Note: Empty state preview requires modifying viewModel
    return view
}
#endif
