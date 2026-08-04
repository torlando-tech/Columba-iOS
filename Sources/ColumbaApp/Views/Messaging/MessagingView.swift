//
//  MessagingView.swift
//  Columba-iOS
//
//  Main chat view with message list, navigation bar, and input bar.
//  Matches Android Columba design with glass material styling.
//

import SwiftUI
import RNSAPI
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
#endif
import os.log
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "network.columba.Columba", category: "MessagingView")

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
    private let settingsRepository = SettingsRepository()

    // MARK: - State

    @State private var viewModel: MessagingViewModel?
    @State private var messageText = ""
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var attachedImage: UIImage?
    @State private var attachedFiles: [FileAttachment] = []
    @State private var showQualityPicker = false
    @State private var pendingRawImage: UIImage?
    @State private var selectedImagePreset: SettingsViewModel.ImageQualityPreset = .high
    @State private var isNearBottom = true
    /// One-shot flag so the post-load scroll-to-bottom only fires the
    /// first time messages populate. Subsequent message arrivals use
    /// `onChange(of: messages.last?.id)` and only scroll when already
    /// near the bottom.
    @State private var didInitialScroll = false
    @State private var detailMessage: Message?
    @State private var deleteConfirmMessage: Message?
    @State private var showLocationConfirm = false
    @State private var showCodecSheet = false
    @State private var emojiPickerTargetMessage: Message?
    @State private var reactionModeMessage: Message?
    @State private var isSavedContact: Bool = false
    /// Set when a voice call can't be placed (no telephony path to the peer)
    /// so the user gets feedback instead of the codec sheet silently dismissing.
    @State private var callUnavailableMessage: String?
    @State private var showTextSizePicker = false
    @State private var messageTextScale = SettingsRepository.MessageTextScale.defaultValue
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        Group {
            if let vm = viewModel {
                #if os(iOS)
                MessageTimelineView(
                    messages: vm.messages,
                    isLoadingMore: vm.isLoadingMore,
                    allMessagesLoaded: vm.allMessagesLoaded,
                    onLoadOlder: {
                        await vm.loadMoreMessages()
                    },
                    onReply: { message in
                        guard message.messageHash != nil else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            vm.replyToMessage = message
                        }
                    },
                    onToggleReaction: { message, emoji in
                        Task {
                            await vm.sendReaction(
                                targetMessageId: message.id,
                                targetMessageHash: message.messageHash,
                                emoji: emoji
                            )
                        }
                    },
                    onLongPress: { message in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            reactionModeMessage = message
                        }
                    }
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    MessageInputBar(
                        text: $messageText,
                        attachedImage: $attachedImage,
                        attachedFiles: $attachedFiles,
                        replyToMessage: vm.replyToMessage,
                        onDismissReply: { withAnimation(.easeInOut(duration: 0.25)) { vm.replyToMessage = nil } },
                        onSend: sendMessage,
                        onImagePicker: { showPhotoPicker = true },
                        onAttachment: { showFilePicker = true }
                    )
                    .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        guard let newItem else { return }
                        Task {
                            do {
                                if let data = try await newItem.loadTransferable(type: Data.self),
                                   let image = UIImage(data: data) {
                                    await MainActor.run {
                                        pendingRawImage = image
                                        selectedImagePreset = UserDefaults.standard.string(forKey: "image_quality_preset")
                                            .flatMap { SettingsViewModel.ImageQualityPreset(rawValue: $0) } ?? .high
                                        showQualityPicker = true
                                    }
                                }
                            } catch {
                                logger.error("Failed to load image: \(error)")
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
                #else
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
                                SwipeToReplyContainer(onReply: {
                                    guard message.messageHash != nil else { return }
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        vm.replyToMessage = message
                                    }
                                }) {
                                    MessageBubble(
                                        message: message,
                                        messageTextScale: messageTextScale,
                                        onToggleReaction: { emoji in
                                            Task {
                                                await vm.sendReaction(
                                                    targetMessageId: message.id,
                                                    targetMessageHash: message.messageHash,
                                                    emoji: emoji
                                                )
                                            }
                                        },
                                        onTapReplyPreview: { replyId in
                                            withAnimation {
                                                proxy.scrollTo(replyId, anchor: .center)
                                            }
                                        },
                                        onLongPress: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                reactionModeMessage = message
                                            }
                                        }
                                    )
                                }
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }

                            // Invisible anchor at bottom: tracks scroll position
                            // AND drives the one-shot initial scroll. `onAppear`
                            // fires only once SwiftUI has actually realized this
                            // 1px row in the layout — which is the exact signal
                            // the previous `.task` + 50 ms sleep was guessing
                            // at, but without the arbitrary delay or the
                            // cancellation race that came with it. If
                            // `.defaultScrollAnchor(.bottom)` lands the
                            // viewport correctly, this row is realized
                            // immediately and the scroll is a no-op; if the
                            // anchor lands inside unrealized space, the
                            // explicit `scrollTo` here forces the LazyVStack
                            // to lay out the bottom and the user sees the
                            // latest message.
                            Color.clear
                                .frame(height: 1)
                                .id("bottom-anchor")
                                .onAppear {
                                    isNearBottom = true
                                    if !didInitialScroll {
                                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                                        didInitialScroll = true
                                    }
                                }
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
                            replyToMessage: vm.replyToMessage,
                            onDismissReply: { withAnimation(.easeInOut(duration: 0.25)) { vm.replyToMessage = nil } },
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
                                                // Store raw image and show quality picker
                                                pendingRawImage = image
                                                selectedImagePreset = UserDefaults.standard.string(forKey: "image_quality_preset")
                                                    .flatMap { SettingsViewModel.ImageQualityPreset(rawValue: $0) } ?? .high
                                                showQualityPicker = true
                                            }
                                        }
                                    }
                                } catch {
                                    logger.error("Failed to load image: \(error)")
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
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        #if canImport(UIKit)
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                        #endif
                    }
                    // First-render anchor is now driven from the
                    // bottom-anchor's `onAppear` (see the LazyVStack
                    // above). That fires exactly when SwiftUI has
                    // realized the 1px row, eliminating both the
                    // arbitrary 50 ms timing window and the
                    // task-cancellation race that the prior
                    // `.task(id:)` approach needed.
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
                }
                #endif
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.backgroundPrimary)
        .overlay {
            if let msg = reactionModeMessage {
                ReactionOverlay(
                    message: msg,
                    onReact: { emoji in
                        Task {
                            await viewModel?.sendReaction(
                                targetMessageId: msg.id,
                                targetMessageHash: msg.messageHash,
                                emoji: emoji
                            )
                        }
                    },
                    onReply: {
                        guard msg.messageHash != nil else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            viewModel?.replyToMessage = msg
                        }
                    },
                    onCopy: {
                        #if os(iOS)
                        UIPasteboard.general.string = msg.content
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(msg.content, forType: .string)
                        #endif
                    },
                    onDetails: {
                        detailMessage = msg
                    },
                    onDelete: {
                        deleteConfirmMessage = msg
                    },
                    onRetry: msg.deliveryStatus == .failed ? {
                        Task { await viewModel?.retryMessage(messageId: msg.id) }
                    } : nil,
                    onMoreEmoji: {
                        emojiPickerTargetMessage = msg
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            reactionModeMessage = nil
                        }
                    }
                )
            }
        }
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .background(InteractivePopGestureEnabler())
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
        .sheet(isPresented: $showQualityPicker) {
            ImageQualityPickerSheet(
                selectedPreset: $selectedImagePreset,
                onConfirm: {
                    if let raw = pendingRawImage {
                        attachedImage = raw.resizedToFit(maxDimension: selectedImagePreset.maxDimension)
                        // Remember choice for next time
                        UserDefaults.standard.set(selectedImagePreset.rawValue, forKey: "image_quality_preset")
                    }
                    pendingRawImage = nil
                    showQualityPicker = false
                },
                onCancel: {
                    pendingRawImage = nil
                    showQualityPicker = false
                }
            )
            .presentationDetents([.height(340)])
            .presentationDragIndicator(.visible)
        }
        // Codec picker → place the voice call. The active/outgoing call UI
        // (VoiceCallScreen) is presented app-root in MainTabView off
        // callManager.callState, so it survives navigating away from the chat.
        .sheet(isPresented: $showCodecSheet) {
            CodecSelectionSheet { profile in
                showCodecSheet = false
                #if os(iOS)
                let dest = conversation.destinationHash
                let name = conversation.peerName
                Task { @MainActor in
                    guard let cm = appServices.callManager else { return }
                    // CallManager resolves this delivery announce to the cached
                    // sibling telephony announce when available, otherwise it
                    // derives <identity>.lxst.telephony. The backend receives
                    // only that telephony hash and actively requests its path.
                    cm.initiateCall(destinationHash: dest, profile: profile, peerDisplayName: name)
                }
                #endif
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $detailMessage) { message in
            MessageDetailView(
                message: message,
                destinationHash: conversation.destinationHash,
                pathTable: appServices.pathTable
            )
        }
        .alert("Delete Message?", isPresented: Binding(
            get: { deleteConfirmMessage != nil },
            set: { if !$0 { deleteConfirmMessage = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                deleteConfirmMessage = nil
            }
            Button("Delete", role: .destructive) {
                if let msg = deleteConfirmMessage {
                    Task {
                        await viewModel?.deleteMessage(messageId: msg.id, messageHash: msg.messageHash)
                    }
                    deleteConfirmMessage = nil
                }
            }
        } message: {
            Text("This message will be permanently deleted from this device.")
        }
        .alert("Call Unavailable", isPresented: Binding(
            get: { callUnavailableMessage != nil },
            set: { if !$0 { callUnavailableMessage = nil } }
        )) {
            Button("OK", role: .cancel) { callUnavailableMessage = nil }
        } message: {
            Text(callUnavailableMessage ?? "")
        }
        #if os(iOS)
        .sheet(isPresented: $showLocationConfirm) {
            LocationShareSheet(onStart: { duration in
                appServices.locationSharingManager?.startSharing(
                    with: conversation.destinationHash,
                    duration: duration
                )
            })
            .presentationDetents([.medium])
        }
        #endif
        .sheet(item: $emojiPickerTargetMessage) { target in
            EmojiPickerSheet { emoji in
                Task {
                    await viewModel?.sendReaction(
                        targetMessageId: target.id,
                        targetMessageHash: target.messageHash,
                        emoji: emoji
                    )
                }
            }
            .presentationDetents([.height(340)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTextSizePicker) {
            TextSizePickerSheet(currentScale: messageTextScale) { selectedScale in
                Task {
                    await settingsRepository.setMessageTextScale(selectedScale)
                    messageTextScale = await settingsRepository.getMessageTextScale()
                }
            }
            .presentationDetents([.height(460), .large])
            .presentationDragIndicator(.visible)
        }
        .onDisappear {
            NotificationService.activeConversationThreadId = nil
        }
        .task {
            messageTextScale = await settingsRepository.getMessageTextScale()
            let threadId = conversation.destinationHash.map { String(format: "%02x", $0) }.joined()
            NotificationService.activeConversationThreadId = threadId
            if let record = try? await messageRepository.fetchConversation(conversation.destinationHash) {
                isSavedContact = record.isFavorite != 0
            } else {
                isSavedContact = conversation.isFavorite
            }
            if viewModel == nil {
                // Load messages before setting viewModel so the ScrollView first
                // appears with content already populated. This lets .defaultScrollAnchor(.bottom)
                // work correctly — if viewModel were set first, the ScrollView would
                // appear with an empty LazyVStack, anchor to the bottom of nothing,
                // then messages would populate from the top.
                let vm = MessagingViewModel(
                    conversationHash: conversation.destinationHash,
                    repository: messageRepository,
                    appServices: appServices,
                    displayName: conversation.displayName
                )
                await vm.loadMessages()
                viewModel = vm
            } else {
                await viewModel?.loadMessages()
            }
        }
    }

    // MARK: - Toolbar Views

    private var leadingToolbar: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var titleView: some View {
        HStack(spacing: 8) {
            Text(conversation.peerName)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Circle()
                .fill(appServices.isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
    }

    @State private var isSyncing = false

    #if os(iOS)
    /// Whether we are currently sharing location with this conversation's peer.
    private var isSharingLocation: Bool {
        appServices.locationSharingManager?.isSharing(with: conversation.destinationHash) ?? false
    }
    #endif

    private var trailingToolbar: some View {
        HStack(spacing: 16) {
            #if os(iOS)
            // Voice call — opens the codec picker, then places an LXST voice
            // call to the peer's telephony destination (resolved from their
            // identity). Restored after the Phase 0 migration removed it.
            // Only shown when a CallManager exists (telephony wired); otherwise
            // the codec sheet would open and then silently no-op on the nil
            // callManager guard, giving the user no feedback.
            if appServices.callManager != nil {
                Button(action: { showCodecSheet = true }) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textPrimary)
                }
                .accessibilityIdentifier("voice_call_button")
                .accessibilityLabel("Voice call")
            }

            // Location sharing toggle
            Button(action: {
                guard let locManager = appServices.locationSharingManager else { return }
                if locManager.isSharing(with: conversation.destinationHash) {
                    locManager.stopSharing(with: conversation.destinationHash)
                } else {
                    showLocationConfirm = true
                }
            }) {
                Image(systemName: isSharingLocation ? "location.fill" : "location.slash")
                    .font(.system(size: 16))
                    .foregroundStyle(isSharingLocation ? .green : Theme.textPrimary)
            }
            // Stable handle for the Tests/interop/ harness so Maestro can
            // toggle sharing without point-percent taps. The accessibility
            // label flips so VoiceOver narrates the current intent of a tap.
            .accessibilityIdentifier("location_share_toggle")
            .accessibilityLabel(isSharingLocation ? "Stop sharing location" : "Share my location")
            #endif

            // More options menu
            Menu {
                Button {
                    showTextSizePicker = true
                } label: {
                    Label("Text Size", systemImage: "textformat.size")
                }
                .accessibilityIdentifier("text_size_menu_item")

                Divider()

                Button {
                    Task {
                        isSyncing = true
                        defer { isSyncing = false }
                        await appServices.propagationManager?.syncNow(userInitiated: true)
                        await viewModel?.loadMessages()
                    }
                } label: {
                    Label("Sync Messages", systemImage: "arrow.clockwise")
                }

                Button {
                    Task {
                        let newValue = !isSavedContact
                        if newValue {
                            try? await messageRepository.ensureConversation(
                                conversation.destinationHash,
                                displayName: conversation.displayName
                            )
                        }
                        try? await messageRepository.setFavorite(conversation.destinationHash, isFavorite: newValue)
                        await MainActor.run {
                            isSavedContact = newValue
                            NotificationCenter.default.post(
                                name: IncomingMessageHandler.messageReceivedNotification,
                                object: nil
                            )
                        }
                    }
                } label: {
                    Label(
                        isSavedContact ? "Remove from Contacts" : "Add to Contacts",
                        systemImage: isSavedContact ? "star.slash" : "star"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = attachedImage
        let files = attachedFiles
        let replyTarget = viewModel?.replyToMessage
        let replyToId = replyTarget?.messageHash != nil ? replyTarget?.id : nil

        guard !text.isEmpty || image != nil || !files.isEmpty else { return }

        messageText = ""
        attachedImage = nil
        attachedFiles = []
        withAnimation(.easeInOut(duration: 0.25)) {
            viewModel?.replyToMessage = nil
        }

        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        #endif

        var imageData: Data?
        var imageFormat: String?
        if let image {
            imageData = image.compressToPreset(selectedImagePreset)
            imageFormat = "jpeg"
            logger.info("Image \(image.size.width)x\(image.size.height) preset=\(selectedImagePreset.rawValue) -> JPEG \(imageData?.count ?? 0) bytes")
        }

        let fileAttachments: [(name: String, data: Data)]? = files.isEmpty ? nil : files.map { ($0.name, $0.data) }

        Task {
            _ = await viewModel?.sendMessage(
                text: text,
                imageData: imageData,
                imageFormat: imageFormat,
                attachments: fileAttachments,
                replyToId: replyToId
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

// MARK: - Image Quality Picker Sheet

@available(iOS 17.0, macOS 14.0, *)
private struct ImageQualityPickerSheet: View {
    @Binding var selectedPreset: SettingsViewModel.ImageQualityPreset
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Image Quality")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 8)

            VStack(spacing: 8) {
                ForEach(SettingsViewModel.ImageQualityPreset.allCases) { preset in
                    Button {
                        selectedPreset = preset
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedPreset == preset ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(selectedPreset == preset ? Theme.accentColor : .gray)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.rawValue)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(preset.description)
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            selectedPreset == preset
                                ? Theme.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Button("Attach") { onConfirm() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(Theme.backgroundSecondary)
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
        #if os(iOS)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return result
        #else
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        draw(in: CGRect(origin: .zero, size: newSize), from: CGRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
        #endif
    }

    /// Compress image to fit within a quality preset's target size.
    /// Resizes first, then iteratively reduces JPEG quality until within budget.
    func compressToPreset(_ preset: SettingsViewModel.ImageQualityPreset) -> Data? {
        let resized = resizedToFit(maxDimension: preset.maxDimension)
        var quality = preset.initialQuality
        var data = resized.jpegData(compressionQuality: quality)
        while let d = data, d.count > preset.targetSizeBytes, quality > preset.minQuality {
            quality -= 0.10
            data = resized.jpegData(compressionQuality: max(quality, preset.minQuality))
        }
        return data
    }
}

// MARK: - Location Share Sheet

// MARK: - Interactive Pop Gesture Enabler

/// Re-enables the native iOS edge-swipe-to-go-back gesture that
/// `.navigationBarBackButtonHidden(true)` disables.
#if canImport(UIKit)
private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        InteractivePopController()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private class InteractivePopController: UIViewController, UIGestureRecognizerDelegate {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        navigationController?.interactivePopGestureRecognizer?.delegate = self
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
    }
}
#endif

// MARK: - Swipe to Reply Container

/// Wraps a message bubble to add swipe-right-to-reply gesture.
@available(iOS 17.0, macOS 14.0, *)
struct SwipeToReplyContainer<Content: View>: View {
    let onReply: () -> Void
    @ViewBuilder let content: Content

    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            // Reply icon revealed behind the bubble
            if dragOffset > 10 {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accentColor.opacity(min(1, dragOffset / 60)))
                    .padding(.leading, 8)
            }

            content
                .offset(x: min(dragOffset * 0.6, 60))
        }
        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.86), value: dragOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 25, coordinateSpace: .local)
                .updating($dragOffset) { value, state, _ in
                    let horizontal = value.translation.width
                    let vertical = abs(value.translation.height)
                    // Only track rightward horizontal swipes
                    if horizontal > 0 && vertical < horizontal * 0.5 {
                        state = horizontal
                    }
                }
                .onEnded { value in
                    let horizontal = value.translation.width
                    let vertical = abs(value.translation.height)
                    if horizontal > 50 && vertical < horizontal * 0.5 {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        onReply()
                    }
                }
        )
    }
}

// MARK: - Emoji Picker Sheet

/// Grid of popular emoji for reaction selection.
@available(iOS 17.0, macOS 14.0, *)
private struct EmojiPickerSheet: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let emojis = [
        "👍", "❤️", "😂", "😮", "😢", "😡",
        "🔥", "👏", "🎉", "💯", "✨", "🙏",
        "😍", "🥰", "😊", "😎", "🤣", "😅",
        "😭", "🤔", "🙄", "😏", "🥲", "😋",
        "👀", "💀", "🫡", "🤝", "💪", "✌️",
        "🖤", "💜", "💙", "💚", "💛", "🧡",
        "⭐", "🌟", "⚡", "🌈", "☀️", "🫶",
        "😤", "😱", "🤮", "😴", "🥳", "🤗",
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Text("Choose Reaction")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Self.emojis, id: \.self) { emoji in
                    Button {
                        onSelect(emoji)
                        dismiss()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .background(Theme.backgroundSecondary)
    }
}

// MARK: - Signal-Style Reaction Overlay

/// Full-screen overlay with emoji bar and action buttons, triggered by long-press on a message.
@available(iOS 17.0, macOS 14.0, *)
private struct ReactionOverlay: View {
    let message: Message
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onDetails: () -> Void
    let onDelete: () -> Void
    var onRetry: (() -> Void)?
    let onMoreEmoji: () -> Void
    let onDismiss: () -> Void

    private static let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "😡"]

    var body: some View {
        ZStack {
            // Dimmed scrim
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 12) {
                // Inline emoji bar
                HStack(spacing: 12) {
                    ForEach(Self.quickEmojis, id: \.self) { emoji in
                        Button {
                            onReact(emoji)
                            onDismiss()
                        } label: {
                            Text(emoji)
                                .font(.system(size: 28))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onDismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onMoreEmoji()
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())

                // Message preview
                HStack {
                    if message.isFromMe { Spacer(minLength: 60) }
                    VStack(alignment: .leading, spacing: 6) {
                        if let imageData = message.imageData,
                           let uiImage = UIImage(data: imageData) {
                            Image(platformImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200, maxHeight: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        if !message.content.isEmpty {
                            Text(message.content)
                                .font(.body)
                                .foregroundStyle(message.isFromMe ? .white : Theme.textPrimary)
                                .lineLimit(4)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.isFromMe
                            ? Theme.sentBubbleColor.opacity(0.85)
                            : Theme.receivedBubbleColor
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if !message.isFromMe { Spacer(minLength: 60) }
                }
                .padding(.horizontal, 16)

                // Action buttons
                HStack(spacing: 0) {
                    actionButton(icon: "arrowshape.turn.up.left", label: "Reply") {
                        onDismiss()
                        onReply()
                    }

                    if !message.content.isEmpty {
                        actionButton(icon: "doc.on.doc", label: "Copy") {
                            onDismiss()
                            onCopy()
                        }
                    }

                    actionButton(icon: "info.circle", label: "Details") {
                        onDismiss()
                        onDetails()
                    }

                    if let onRetry {
                        actionButton(icon: "arrow.clockwise", label: "Retry") {
                            self.onDismiss()
                            onRetry()
                        }
                    }

                    actionButton(icon: "trash", label: "Delete", isDestructive: true) {
                        onDismiss()
                        onDelete()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 16)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private func actionButton(
        icon: String,
        label: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(isDestructive ? .red : Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

#if os(iOS)
/// Bottom sheet for selecting location sharing duration before starting.
private struct LocationShareSheet: View {
    let onStart: (SharingDuration) -> Void
    @State private var selected: SharingDuration = {
        if let raw = UserDefaults.standard.string(forKey: "default_sharing_duration"),
           let duration = SharingDuration.allCases.first(where: { $0.rawValue == raw }) {
            return duration
        }
        return .oneHour
    }()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // Handle bar
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Spacer().frame(height: 8)

            Text("Share Location")
                .font(.title3.bold())

            Text("Your live location will be sent\nperiodically to this contact.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            // Duration options
            VStack(spacing: 0) {
                ForEach(SharingDuration.allCases) { duration in
                    Button {
                        selected = duration
                    } label: {
                        HStack {
                            Text(duration.rawValue)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if selected == duration {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    if duration != SharingDuration.allCases.last {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            Button {
                onStart(selected)
                dismiss()
            } label: {
                Text("Start Sharing")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            Spacer()
        }
    }
}
#endif
