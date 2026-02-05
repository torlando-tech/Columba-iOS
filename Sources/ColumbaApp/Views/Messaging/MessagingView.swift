//
//  MessagingView.swift
//  Columba-iOS
//
//  Main chat view with message list, navigation bar, and input bar.
//  Matches Android Columba design with glass material styling.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Main messaging/chat screen view.
///
/// Layout:
/// - Navigation bar: back, peer name with status, action icons
/// - ScrollView with message bubbles
/// - MessageInputBar pinned at bottom
struct MessagingView: View {
    // MARK: - Properties

    @State private var viewModel: MessagingViewModel
    @State private var messageText = ""
    @Environment(\.dismiss) private var dismiss

    let peerName: String
    let isOnline: Bool

    // MARK: - Initialization

    init(viewModel: MessagingViewModel, peerName: String, isOnline: Bool = false) {
        _viewModel = State(initialValue: viewModel)
        self.peerName = peerName
        self.isOnline = isOnline
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Messages scroll view
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: viewModel.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onAppear {
                    scrollToBottom(proxy: proxy, animated: false)
                }
            }

            // Input bar
            MessageInputBar(
                text: $messageText,
                onSend: sendMessage,
                onImagePicker: {
                    // Image picker action
                },
                onAttachment: {
                    // Attachment action
                }
            )
        }
        .background(Color.black)
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                leadingToolbar
            }
            ToolbarItem(placement: .principal) {
                titleView
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                trailingToolbar
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #else
        .toolbar {
            ToolbarItem(placement: .navigation) {
                leadingToolbar
            }
            ToolbarItem(placement: .principal) {
                titleView
            }
        }
        #endif
        .task {
            await viewModel.loadMessages()
        }
    }

    // MARK: - Toolbar Views

    private var leadingToolbar: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var titleView: some View {
        HStack(spacing: 8) {
            Text(peerName)
                .font(.headline)
                .foregroundStyle(.white)

            Circle()
                .fill(isOnline ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
    }

    private var trailingToolbar: some View {
        HStack(spacing: 16) {
            Button(action: { /* Phone action */ }) {
                Image(systemName: "phone")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }

            Button(action: { /* Location action */ }) {
                Image(systemName: "location")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }

            Button(action: { /* Star/favorite action */ }) {
                Image(systemName: "star")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }

            Button(action: {
                Task {
                    await viewModel.loadMessages()
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messageText = ""

        // Haptic feedback
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        #endif

        Task {
            await viewModel.sendMessage(text: text)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        guard let lastMessage = viewModel.messages.last else { return }

        if animated {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MessagingView(
            viewModel: MessagingViewModel(),
            peerName: "Peer DB3FFD25",
            isOnline: true
        )
    }
    .preferredColorScheme(.dark)
}
