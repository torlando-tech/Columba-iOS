//
//  SettingsView.swift
//  Columba-iOS
//
//  Main settings screen with expandable cards for each category.
//  Matches Android Columba design with glass material styling.
//

import SwiftUI
import LXMFSwift

/// Main settings screen view.
///
/// Displays expandable cards for each settings category:
/// - Network
/// - Identity (with View My Identity and Manage Identities buttons)
/// - Privacy (with toggle)
/// - Notifications (with toggle, default on)
/// - Auto Announce (with toggle, default on)
/// - Location Sharing (with toggle)
/// - Map Sources
@available(iOS 17.0, macOS 14.0, *)
struct SettingsView: View {
    // MARK: - Dependencies

    let appServices: AppServices
    let settingsRepository: SettingsRepository
    let identityManager: IdentityManager
    var onIdentitySwitch: (() -> Void)?

    // MARK: - State

    @State private var viewModel: SettingsViewModel?
    @State private var showMyIdentity = false
    @State private var showManageIdentities = false
    @State private var showInterfaceManagement = false
    @State private var showNetworkStatus = false
    @State private var showBLEConnections = false
    @State private var showDataMigration = false
    @State private var interfaceRepository: InterfaceRepository?
    /// Persisted across body re-evaluations so showRNodeWizard=true is not lost
    /// when SettingsView re-renders due to connection status polling changes.
    @State private var interfaceViewModel: InterfaceManagementViewModel?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            if let vm = viewModel {
                ScrollView {
                    VStack(spacing: 12) {
                        // Network
                        networkCard(vm)

                        // Delivery & Retrieval
                        deliveryRetrievalCard(vm)

                        // Appearance
                        AppearanceCard(
                            isExpanded: Binding(get: { vm.isAppearanceExpanded }, set: { vm.isAppearanceExpanded = $0 })
                        )

                        // Identity
                        identityCard(vm)

                        // Privacy
                        privacyCard(vm)

                        // Notifications
                        notificationsCard(vm)

                        // Auto Announce
                        autoAnnounceCard(vm)

                        // Location Sharing
                        locationSharingCard(vm)

                        // Map Sources
                        mapSourcesCard(vm)

                        // Data Migration
                        dataMigrationCard(vm)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Theme.backgroundPrimary)
                .navigationTitle("Settings")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                #endif
                .navigationDestination(isPresented: $showMyIdentity) {
                    MyIdentityView(viewModel: vm)
                }
                .navigationDestination(isPresented: $showInterfaceManagement) {
                    if let vm = interfaceViewModel {
                        InterfaceManagementScreen(viewModel: vm)
                    }
                }
                .navigationDestination(isPresented: $showNetworkStatus) {
                    NetworkStatusView(appServices: appServices)
                }
                .navigationDestination(isPresented: $showBLEConnections) {
                    BLEConnectionsView(appServices: appServices)
                }
                .navigationDestination(isPresented: $showManageIdentities) {
                    IdentityManagerView(
                        identityManager: identityManager,
                        appServices: appServices,
                        settingsRepository: settingsRepository,
                        onIdentitySwitch: onIdentitySwitch
                    )
                }
                .navigationDestination(isPresented: $showDataMigration) {
                    MigrationScreen(
                        identityManager: identityManager,
                        settingsRepository: settingsRepository
                    )
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // RNode wizard fullScreenCover is anchored HERE (on NavigationStack root) rather
        // than on InterfaceManagementScreen.  This prevents the wizard from being
        // dismissed when SettingsView re-renders due to connection-status polling:
        // previously, the viewModel was created inline in .navigationDestination, so
        // each re-render produced a fresh InterfaceManagementViewModel with
        // showRNodeWizard=false, which immediately dismissed the fullScreenCover.
        .fullScreenCover(isPresented: Binding(
            get: { interfaceViewModel?.showRNodeWizard ?? false },
            set: { interfaceViewModel?.showRNodeWizard = $0 }
        )) {
            if let vm = interfaceViewModel {
                RNodeWizardView(viewModel: vm)
            }
        }
        .task {
            if viewModel == nil {
                viewModel = SettingsViewModel(
                    appServices: appServices,
                    settingsRepository: settingsRepository,
                    identityManager: identityManager
                )
            }
            await viewModel?.loadSettings()
        }
    }

    // MARK: - Network Card

    private func networkCard(_ vm: SettingsViewModel) -> some View {
        ExpandableSettingsCard(
            icon: "antenna.radiowaves.left.and.right",
            title: "Network",
            isExpanded: Binding(get: { vm.isNetworkExpanded }, set: { vm.isNetworkExpanded = $0 })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Configure network interfaces and connection settings for Reticulum.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                HStack {
                    Text("Status:")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    Circle()
                        .fill(vm.isConnected ? Theme.success : Theme.error)
                        .frame(width: 8, height: 8)

                    Text(vm.isConnected ? "Connected" : "Disconnected")
                        .font(.subheadline)
                        .foregroundStyle(vm.isConnected ? Theme.success : Theme.error)
                }

                if vm.isConnected {
                    HStack {
                        Text("Interface:")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)

                        Text(vm.connectedInterface)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                // View Network Status Button
                Button(action: {
                    showNetworkStatus = true
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 14, weight: .medium))
                        Text("View Network Status")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }

                // Manage Interfaces Button
                Button(action: {
                    if interfaceRepository == nil {
                        let repo = InterfaceRepository()
                        interfaceRepository = repo
                        interfaceViewModel = InterfaceManagementViewModel(
                            repository: repo,
                            appServices: appServices
                        )
                    }
                    showInterfaceManagement = true
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                        Text("Manage Interfaces")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }

                // BLE Connections Button
                Button(action: {
                    showBLEConnections = true
                }) {
                    HStack(spacing: 8) {
                        if let ch = MaterialDesignIcons.character(for: "bluetooth") {
                            Text(String(ch))
                                .font(.custom(MaterialDesignIcons.fontName, size: 14))
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 14, weight: .medium))
                        }
                        Text("BLE Connections")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
            }
        }
    }

    // MARK: - Identity Card

    private func identityCard(_ vm: SettingsViewModel) -> some View {
        ExpandableSettingsCard(
            icon: "person.fill",
            title: "Identity",
            isExpanded: Binding(get: { vm.isIdentityExpanded }, set: { vm.isIdentityExpanded = $0 })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("View and share your identity, edit your display name, and manage QR codes for contact sharing.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                Text("Create and manage multiple identities for different contexts (work, personal, anonymous).")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if !vm.activeIdentityName.isEmpty {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.accentColor)
                            .frame(width: 8, height: 8)
                        Text("Active: \(vm.activeIdentityName)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.accentColor)
                    }
                }

                // View My Identity Button
                Button(action: { showMyIdentity = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 14, weight: .medium))
                        Text("View My Identity")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }

                // Manage Identities Button
                Button(action: { showManageIdentities = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                        Text("Manage Identities")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
            }
        }
    }

    // MARK: - Privacy Card

    private func privacyCard(_ vm: SettingsViewModel) -> some View {
        ExpandableSettingsCard(
            icon: "shield.fill",
            title: "Privacy",
            isExpanded: Binding(get: { vm.isPrivacyExpanded }, set: { vm.isPrivacyExpanded = $0 }),
            toggle: Binding(get: { vm.blockUnknownSenders }, set: { newValue in
                vm.blockUnknownSenders = newValue
                vm.saveSettings()
            })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(vm.blockUnknownSenders
                    ? "Only contacts can message you. Messages from unknown senders are silently discarded."
                    : "Anyone can send you messages, including unknown senders.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Notifications Card

    private func notificationsCard(_ vm: SettingsViewModel) -> some View {
        ExpandableSettingsCard(
            icon: "bell.fill",
            title: "Notifications",
            isExpanded: Binding(get: { vm.isNotificationsExpanded }, set: { vm.isNotificationsExpanded = $0 }),
            toggle: Binding(get: { vm.isNotificationsEnabled }, set: { newValue in
                vm.isNotificationsEnabled = newValue
                vm.saveSettings()
                if newValue {
                    Task { await NotificationService.shared.requestPermission() }
                }
            })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Configure how you receive notifications for incoming messages and announcements.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if vm.isNotificationsEnabled {
                    settingsToggleRow(
                        title: "Message Previews",
                        isOn: Binding(get: { vm.showMessagePreviews }, set: {
                            vm.showMessagePreviews = $0
                            vm.saveSettings()
                        })
                    )

                    settingsToggleRow(
                        title: "Sound",
                        isOn: Binding(get: { vm.playSounds }, set: {
                            vm.playSounds = $0
                            vm.saveSettings()
                        })
                    )

                    settingsToggleRow(
                        title: "Vibrate",
                        isOn: Binding(get: { vm.vibrate }, set: {
                            vm.vibrate = $0
                            vm.saveSettings()
                        })
                    )
                }
            }
        }
    }

    // MARK: - Auto Announce Card

    private func autoAnnounceCard(_ vm: SettingsViewModel) -> some View {
        ExpandableSettingsCard(
            icon: "antenna.radiowaves.left.and.right",
            title: "Auto Announce",
            isExpanded: Binding(get: { vm.isAutoAnnounceExpanded }, set: { vm.isAutoAnnounceExpanded = $0 }),
            toggle: Binding(get: { vm.isAutoAnnounceEnabled }, set: { newValue in
                vm.isAutoAnnounceEnabled = newValue
                vm.saveSettings()
                vm.syncAutoAnnounce()
            })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Automatically announce your presence on the network at regular intervals. This helps other peers discover you.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if vm.isAutoAnnounceEnabled {
                    // Interval selector
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Announce Interval: \(vm.announceIntervalHours) hour\(vm.announceIntervalHours == 1 ? "" : "s")")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.accentColor)

                        // Preset chips
                        HStack(spacing: 8) {
                            ForEach([1, 3, 6, 12], id: \.self) { hours in
                                Button {
                                    vm.announceIntervalHours = hours
                                    vm.saveSettings()
                                    vm.syncAutoAnnounce()
                                } label: {
                                    Text("\(hours)h")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(vm.announceIntervalHours == hours ? .white : Theme.textSecondary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(
                                            vm.announceIntervalHours == hours
                                                ? Theme.accentColor
                                                : Theme.backgroundTertiary
                                        )
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    // Announce status
                    VStack(alignment: .leading, spacing: 4) {
                        if let last = vm.lastAnnounceTime {
                            HStack(spacing: 4) {
                                Text("Last announce:")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Text(last, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Text("ago")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        } else {
                            Text("No announces sent yet")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        if let next = vm.nextAnnounceTime, next > Date() {
                            HStack(spacing: 4) {
                                Text("Next announce in:")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.accentColor)
                                Text(next, style: .relative)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.accentColor)
                            }
                        }
                    }

                    // Announce Now button
                    HStack {
                        Spacer()
                        Button {
                            Task { await vm.triggerManualAnnounce() }
                        } label: {
                            HStack(spacing: 6) {
                                if vm.isManualAnnouncing {
                                    ProgressView()
                                        .tint(Theme.accentColor)
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "paperplane")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                Text(vm.isManualAnnouncing ? "Announcing..." : "Announce Now")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundStyle(Theme.accentColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.accentColor.opacity(0.5), lineWidth: 1)
                            )
                        }
                        .disabled(vm.isManualAnnouncing)
                    }

                    // Success / error feedback
                    if vm.manualAnnounceSuccess {
                        HStack(spacing: 4) {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.success)
                            Text("Announce sent!")
                                .font(.caption)
                                .foregroundStyle(Theme.success)
                        }
                    }

                    if let error = vm.manualAnnounceError {
                        HStack(spacing: 4) {
                            Spacer()
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.error)
                            Text("Error: \(error)")
                                .font(.caption)
                                .foregroundStyle(Theme.error)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Location Sharing Card

    private func locationSharingCard(_ vm: SettingsViewModel) -> some View {
        ExpandableSettingsCard(
            icon: "location.fill",
            title: "Location Sharing",
            isExpanded: Binding(get: { vm.isLocationSharingExpanded }, set: { vm.isLocationSharingExpanded = $0 }),
            toggle: Binding(get: { vm.isLocationSharingEnabled }, set: { vm.isLocationSharingEnabled = $0 })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Share your location with contacts. Your location is end-to-end encrypted and only visible to peers you communicate with.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if vm.isLocationSharingEnabled {
                    settingsToggleRow(
                        title: "Precise Location",
                        isOn: Binding(get: { vm.sharePreciseLocation }, set: { vm.sharePreciseLocation = $0 })
                    )

                    HStack {
                        Text("Update Interval")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)

                        Spacer()

                        Picker("", selection: Binding(get: { vm.locationUpdateInterval }, set: { vm.locationUpdateInterval = $0 })) {
                            Text("30 sec").tag(30)
                            Text("1 min").tag(60)
                            Text("5 min").tag(300)
                            Text("15 min").tag(900)
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.accentColor)
                    }
                }
            }
        }
    }

    // MARK: - Map Sources Card

    private func mapSourcesCard(_ vm: SettingsViewModel) -> some View {
        ExpandableSettingsCard(
            icon: "map.fill",
            title: "Map Sources",
            isExpanded: Binding(get: { vm.isMapSourcesExpanded }, set: { vm.isMapSourcesExpanded = $0 })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose the map provider for viewing contact locations.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                ForEach(SettingsViewModel.MapSource.allCases) { source in
                    mapSourceRow(vm, source: source)
                }
            }
        }
    }

    // MARK: - Delivery & Retrieval Card

    private func deliveryRetrievalCard(_ vm: SettingsViewModel) -> some View {
        ExpandableSettingsCard(
            icon: "arrow.triangle.swap",
            title: "Message Delivery & Retrieval",
            isExpanded: Binding(get: { vm.isDeliveryRetrievalExpanded }, set: { vm.isDeliveryRetrievalExpanded = $0 })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Configure how messages are sent and retrieved from propagation nodes.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                // Default Delivery Method
                HStack {
                    Text("Default Method")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    Spacer()

                    Picker("", selection: Binding(
                        get: { vm.defaultDeliveryMethod },
                        set: {
                            vm.defaultDeliveryMethod = $0
                            Task { await vm.saveDeliverySettings() }
                        }
                    )) {
                        Text("Direct").tag("direct")
                        Text("Propagated").tag("propagated")
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accentColor)
                }

                // Retry via Relay toggle
                settingsToggleRow(
                    title: "Retry via Relay",
                    isOn: Binding(
                        get: { vm.retryViaRelay },
                        set: {
                            vm.retryViaRelay = $0
                            Task { await vm.saveDeliverySettings() }
                        }
                    )
                )

                Divider()
                    .padding(.vertical, 4)

                // RELAY SELECTION
                Text("RELAY SELECTION")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textSecondary)

                settingsToggleRow(
                    title: "Auto-select Relay",
                    isOn: Binding(
                        get: { vm.autoSelectRelay },
                        set: {
                            vm.autoSelectRelay = $0
                            Task { await vm.saveDeliverySettings() }
                        }
                    )
                )

                // Current relay display
                HStack {
                    Text("Current Relay:")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    Spacer()

                    Text(vm.selectedRelayName ?? "None")
                        .font(.subheadline)
                        .foregroundStyle(vm.selectedRelayName != nil ? Theme.textPrimary : Theme.textSecondary)
                }

                Divider()
                    .padding(.vertical, 4)

                // MESSAGE RETRIEVAL
                Text("MESSAGE RETRIEVAL")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textSecondary)

                settingsToggleRow(
                    title: "Auto-retrieve Messages",
                    isOn: Binding(
                        get: { vm.autoRetrieveEnabled },
                        set: {
                            vm.autoRetrieveEnabled = $0
                            Task { await vm.saveDeliverySettings() }
                        }
                    )
                )

                if vm.autoRetrieveEnabled {
                    HStack {
                        Text("Interval")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)

                        Spacer()

                        Picker("", selection: Binding(
                            get: { vm.autoRetrieveInterval },
                            set: {
                                vm.autoRetrieveInterval = $0
                                Task { await vm.saveDeliverySettings() }
                            }
                        )) {
                            Text("1 hour").tag(TimeInterval(3600))
                            Text("3 hours").tag(TimeInterval(10800))
                            Text("6 hours").tag(TimeInterval(21600))
                            Text("12 hours").tag(TimeInterval(43200))
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.accentColor)
                    }
                }

                // Sync Now button
                Button(action: {
                    Task { await vm.syncNow() }
                }) {
                    HStack(spacing: 8) {
                        if vm.isSyncing {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                        }
                        Text(vm.isSyncing ? "Syncing..." : "Sync Now")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accentColor.opacity(vm.isSyncing ? 0.6 : 1.0))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
                .disabled(vm.isSyncing)

                // Last sync time
                if let lastSync = vm.lastSyncTime {
                    HStack {
                        Text("Last Sync:")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)

                        Text(lastSync, style: .relative)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)

                        Text("ago")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                // Sync error
                if let error = vm.syncError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.error)
                }
            }
        }
    }

    // MARK: - Data Migration Card

    private func dataMigrationCard(_ vm: SettingsViewModel) -> some View {
        Button {
            showDataMigration = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accentColor)
                    .frame(width: 24, height: 24)

                Text("Data Migration")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassCard()
        }
    }

    // MARK: - Helper Views

    private func settingsToggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(AccentToggleStyle())
                .labelsHidden()
        }
    }

    private func mapSourceRow(_ vm: SettingsViewModel, source: SettingsViewModel.MapSource) -> some View {
        Button(action: {
            vm.selectedMapSource = source
        }) {
            HStack {
                Text(source.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                if vm.selectedMapSource == source {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accentColor)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Preview

// Note: Preview disabled - requires AppServices and SettingsRepository dependencies
// To preview, use the simulator with the full app.
