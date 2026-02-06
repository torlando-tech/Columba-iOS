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

    // MARK: - State

    @State private var viewModel: SettingsViewModel?
    @State private var showMyIdentity = false
    @State private var showManageIdentities = false
    @State private var showInterfaceManagement = false
    @State private var showNetworkStatus = false
    @State private var interfaceRepository: InterfaceRepository?

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
                    if let repo = interfaceRepository {
                        InterfaceManagementScreen(
                            viewModel: InterfaceManagementViewModel(
                                repository: repo,
                                appServices: appServices
                            )
                        )
                    }
                }
                .navigationDestination(isPresented: $showNetworkStatus) {
                    NetworkStatusView(appServices: appServices)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if viewModel == nil {
                viewModel = SettingsViewModel(
                    appServices: appServices,
                    settingsRepository: settingsRepository
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
                        interfaceRepository = InterfaceRepository()
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
            toggle: Binding(get: { vm.isPrivacyEnabled }, set: { vm.isPrivacyEnabled = $0 })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enable privacy mode to hide message previews and sensitive information from notifications and the app switcher.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if vm.isPrivacyEnabled {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text("Privacy mode is active")
                            .font(.subheadline)
                            .foregroundStyle(Theme.success)
                    }
                }
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
            toggle: Binding(get: { vm.isAutoAnnounceEnabled }, set: { vm.isAutoAnnounceEnabled = $0 })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Automatically announce your presence on the network so others can discover and message you.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if vm.isAutoAnnounceEnabled {
                    settingsToggleRow(
                        title: "Announce on Launch",
                        isOn: Binding(get: { vm.announceOnLaunch }, set: { vm.announceOnLaunch = $0 })
                    )

                    HStack {
                        Text("Interval")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)

                        Spacer()

                        Picker("", selection: Binding(get: { vm.announceIntervalMinutes }, set: { vm.announceIntervalMinutes = $0 })) {
                            Text("5 min").tag(5)
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                            Text("1 hour").tag(60)
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.accentColor)
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
