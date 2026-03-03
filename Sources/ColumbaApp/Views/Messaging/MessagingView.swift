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
import os.log
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "com.columba.app", category: "MessagingView")

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
    @State private var showQualityPicker = false
    @State private var pendingRawImage: UIImage?
    @State private var selectedImagePreset: SettingsViewModel.ImageQualityPreset = .high
    @State private var isNearBottom = true
    @State private var showCallScreen = false
    @State private var detailMessage: Message?
    @State private var deleteConfirmMessage: Message?
    @State private var showLocationConfirm = false
    @State private var isSavedContact: Bool = false
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
                                MessageBubble(
                                    message: message,
                                    onRetry: message.deliveryStatus == .failed ? {
                                        Task { await vm.retryMessage(messageId: message.id) }
                                    } : nil,
                                    onShowDetails: {
                                        detailMessage = message
                                    },
                                    onDelete: {
                                        deleteConfirmMessage = message
                                    },
                                    onReply: {
                                        vm.replyToMessage = message
                                    },
                                    onReact: { emoji in
                                        Task {
                                            await vm.sendReaction(
                                                targetMessageId: message.id,
                                                targetMessageHash: message.messageHash,
                                                emoji: emoji
                                            )
                                        }
                                    },
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
                                    }
                                )
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
                            replyToMessage: vm.replyToMessage,
                            onDismissReply: { vm.replyToMessage = nil },
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
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.backgroundPrimary)
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .onEnded { value in
                    if value.translation.width > 80 && abs(value.translation.height) < 100 {
                        dismiss()
                    }
                }
        )
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
        .sheet(item: $detailMessage) { message in
            MessageDetailView(message: message)
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
        .sheet(isPresented: $showLocationConfirm) {
            LocationShareSheet(onStart: { duration in
                appServices.locationSharingManager?.startSharing(
                    with: conversation.destinationHash,
                    duration: duration
                )
            })
            .presentationDetents([.medium])
        }
        .onDisappear {
            NotificationService.activeConversationThreadId = nil
        }
        .task {
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
                        .foregroundStyle(Theme.textPrimary)
                }
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

            // More options menu
            Menu {
                Button {
                    Task {
                        isSyncing = true
                        defer { isSyncing = false }
                        await appServices.propagationManager?.syncNow()
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
        let replyToId = viewModel?.replyToMessage?.id

        guard !text.isEmpty || image != nil || !files.isEmpty else { return }

        messageText = ""
        attachedImage = nil
        attachedFiles = []
        viewModel?.replyToMessage = nil

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
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return result
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
