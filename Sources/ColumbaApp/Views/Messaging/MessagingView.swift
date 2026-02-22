//
//  MessagingView.swift
//  Columba-iOS
//
//  Main chat view with message list, navigation bar, and input bar.
//  Matches Android Columba design with glass material styling.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import LXMFSwift
import LXSTSwift
#if canImport(UIKit)
import UIKit
#endif

/// Main messaging/chat screen view.
///
/// Layout:
/// - Navigation bar: back, peer name with status, action icons
/// - ScrollView with message bubbles (fills screen)
/// - MessageInputBar as a safeAreaInset at the bottom
///
/// The safeAreaInset pattern is the SwiftUI-canonical approach for messaging views:
/// it extends the scroll view's bottom safe area by the input bar height, so iOS
/// automatically moves the input bar above the keyboard and the scroll view's
/// visible area is correctly sized — no manual keyboard height tracking needed.
@available(iOS 17.0, macOS 14.0, *)
struct MessagingView: View {
    // MARK: - Dependencies

    let conversation: Conversation
    let appServices: AppServices
    let messageRepository: MessageRepository

    // MARK: - State

    @State private var viewModel: MessagingViewModel?
    @State private var messageText = ""
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var attachedImage: UIImage?
    @State private var attachedFiles: [FileAttachment] = []
    @State private var showCodecPicker = false
    @State private var isNearBottom = true
    @State private var showCallScreen = false
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        Group {
            if let vm = viewModel {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            // Load-more trigger at top
                            if !vm.allMessagesLoaded {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .onAppear {
                                        Task {
                                            await vm.loadMoreMessages()
                                        }
                                    }
                            }

                            ForEach(vm.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            }

                            // Invisible anchor at bottom to track scroll position
                            Color.clear
                                .frame(height: 1)
                                .id("bottom-anchor")
                                .onAppear { isNearBottom = true }
                                .onDisappear { isNearBottom = false }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    // Input bar as a safe area inset: iOS automatically moves it above
                    // the keyboard and adjusts the scroll view's visible area to match.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        MessageInputBar(
                            text: $messageText,
                            attachedImage: $attachedImage,
                            attachedFiles: $attachedFiles,
                            onSend: sendMessage,
                            onImagePicker: { showPhotoPicker = true },
                            onAttachment: { showFilePicker = true }
                        )
                        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
                        .onChange(of: selectedPhotoItem) { _, newItem in
                            guard let newItem else { return }
                            Task {
                                do {
                                    if let data = try await newItem.loadTransferable(type: Data.self) {
                                        if let image = UIImage(data: data) {
                                            await MainActor.run {
                                                attachedImage = image.resizedToFit(maxDimension: 1280)
                                            }
                                        }
                                    }
                                } catch {
                                    print("[PHOTO_PICKER] Failed to load image: \(error)")
                                }
                                await MainActor.run {
                                    selectedPhotoItem = nil
                                }
                            }
                        }
                        .fileImporter(
                            isPresented: $showFilePicker,
                            allowedContentTypes: [.data],
                            allowsMultipleSelection: true
                        ) { result in
                            if case .success(let urls) = result {
                                for url in urls {
                                    guard url.startAccessingSecurityScopedResource() else { continue }
                                    defer { url.stopAccessingSecurityScopedResource() }
                                    if let data = try? Data(contentsOf: url) {
                                        attachedFiles.append(FileAttachment(name: url.lastPathComponent, data: data))
                                    }
                                }
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        #if canImport(UIKit)
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                        #endif
                    }
                    // Scroll to bottom when a new message arrives (if already near bottom)
                    .onChange(of: vm.messages.last?.id) { _, _ in
                        if isNearBottom {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                    // Scroll to bottom when the keyboard appears so the latest message
                    // stays visible above the keyboard.
                    #if canImport(UIKit)
                    .task {
                        for await _ in NotificationCenter.default.notifications(
                            named: UIResponder.keyboardWillShowNotification
                        ) {
                            guard isNearBottom else { continue }
                            // Brief delay lets the keyboard animation begin before we scroll,
                            // so the scroll lands in the right position.
                            try? await Task.sleep(for: .milliseconds(100))
                            scrollToBottom(proxy: proxy)
                        }
                    }
                    #endif
                    .onAppear {
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        .sheet(isPresented: $showCodecPicker) {
            CodecSelectionSheet { profile in
                showCallScreen = true
                appServices.callManager?.initiateCall(
                    destinationHash: conversation.destinationHash,
                    profile: profile,
                    peerDisplayName: conversation.displayName
                )
            }
        }
        .fullScreenCover(isPresented: $showCallScreen) {
            if let cm = appServices.callManager {
                VoiceCallScreen(
                    callManager: cm,
                    peerName: conversation.peerName,
                    destinationHash: conversation.destinationHash
                )
            }
        }
        .task {
            if viewModel == nil {
                viewModel = MessagingViewModel(
                    conversationHash: conversation.destinationHash,
                    repository: messageRepository,
                    appServices: appServices,
                    displayName: conversation.displayName
                )
            }
            await viewModel?.loadMessages()
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
            Text(conversation.peerName)
                .font(.headline)
                .foregroundStyle(.white)

            Circle()
                .fill(appServices.isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
    }

    @State private var isSyncing = false

    /// Whether we are currently sharing location with this conversation's peer.
    private var isSharingLocation: Bool {
        appServices.locationSharingManager?.isSharing(with: conversation.destinationHash) ?? false
    }

    private var trailingToolbar: some View {
        HStack(spacing: 16) {
            // Voice call button
            if appServices.callManager != nil {
                Button(action: { showCodecPicker = true }) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
            }

            // Location sharing toggle
            Button(action: {
                guard let locManager = appServices.locationSharingManager else { return }
                if locManager.isSharing(with: conversation.destinationHash) {
                    locManager.stopSharing(with: conversation.destinationHash)
                } else {
                    locManager.startSharing(with: conversation.destinationHash)
                }
            }) {
                Image(systemName: isSharingLocation ? "location.fill" : "location.slash")
                    .font(.system(size: 16))
                    .foregroundStyle(isSharingLocation ? .green : .white)
            }

            // Sync button
            Button(action: {
                Task {
                    isSyncing = true
                    defer { isSyncing = false }
                    await appServices.propagationManager?.syncNow()
                    await viewModel?.loadMessages()
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(isSyncing ? 360 : 0))
                    .animation(
                        isSyncing
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: isSyncing
                    )
            }
            .disabled(isSyncing)
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = attachedImage
        let files = attachedFiles

        guard !text.isEmpty || image != nil || !files.isEmpty else { return }

        messageText = ""
        attachedImage = nil
        attachedFiles = []

        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        #endif

        var imageData: Data?
        var imageFormat: String?
        if let image {
            imageData = image.jpegData(compressionQuality: 0.75)
            imageFormat = "jpeg"
            print("[SEND_IMG] Image \(image.size.width)x\(image.size.height) -> JPEG \(imageData?.count ?? 0) bytes")
        }

        let fileAttachments: [(name: String, data: Data)]? = files.isEmpty ? nil : files.map { ($0.name, $0.data) }

        Task {
            _ = await viewModel?.sendMessage(
                text: text,
                imageData: imageData,
                imageFormat: imageFormat,
                attachments: fileAttachments
            )
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}

// MARK: - UIImage Resize Helper

extension UIImage {
    /// Resize image to fit within a maximum dimension while preserving aspect ratio.
    /// Uses scale factor 1.0 to produce actual-pixel-sized output (matching Sideband behavior).
    func resizedToFit(maxDimension: CGFloat) -> UIImage {
        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        if ratio >= 1.0 { return self }
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return result
    }
}
