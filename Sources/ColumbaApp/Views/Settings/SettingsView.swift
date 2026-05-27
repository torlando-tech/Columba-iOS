//
//  SettingsView.swift
//  Columba-iOS
//
//  Main settings screen with expandable cards for each category.
//  Matches Android Columba design with glass material styling.
//

import SwiftUI
import RNSAPI

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
    /// Session-scoped flag from MainTabView requesting the RNode wizard.
    /// Cleared by SettingsView only after the wizard has actually been triggered.
    @Binding var shouldOpenRNodeWizard: Bool

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

                        // Background Transport — the Network Extension VPN
                        // tunnel that keeps RNS alive when the app is
                        // backgrounded. Hidden under the Python RNS stack
                        // because the previous implementation routed
                        // reticulum-swift's TCP socket through
                        // PacketTunnelProvider; Python's RNS owns its
                        // sockets and needs a different architecture
                        // (likely a Network Extension that pumps the
                        // Python event loop, or a background-task wake
                        // approach). Phase 2 work.
                        #if ENABLE_NETWORK_EXTENSION
                        backgroundTransportCard()
                        #endif

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

                        // Location Sharing — shown only when the active
                        // backend implements telemetry/location (the Python
                        // backend stubs it; the native backend supports it).
                        // Honest capability gate, not a silent dead-end toggle.
                        if appServices.capabilities.telemetry.storeOwnTelemetry != .unsupported {
                            locationSharingCard(vm)
                        }

                        // Map Sources
                        mapSourcesCard(vm)

                        // Data Migration
                        dataMigrationCard(vm)

                        // Advanced section anchor — separates Transport
                        // Mode (and future advanced settings) from the
                        // common day-to-day toggles above. Mirrors the
                        // grouping introduced in Columba Android.
                        advancedSectionHeader

                        // Transport Mode (advanced)
                        transportModeCard(vm)
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
                    #if COLUMBA_MIGRATION_ENABLED
                    MigrationScreen(
                        identityManager: identityManager,
                        settingsRepository: settingsRepository
                    )
                    #else
                    Text("Data migration unavailable in this build")
                    #endif
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
        #if os(iOS) && COLUMBA_RNODE_ENABLED
        .fullScreenCover(isPresented: Binding(
            get: { interfaceViewModel?.showRNodeWizard ?? false },
            set: { interfaceViewModel?.showRNodeWizard = $0 }
        )) {
            if let vm = interfaceViewModel {
                RNodeWizardView(viewModel: vm)
            }
        }
        #endif
        .onAppear {
            viewModel?.refreshSyncState()
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

            // If MainTabView handed off an RNode wizard request, launch it now.
            // Use selectInterfaceType so configType is set before validation runs
            // when the user taps "Configure RNode" at the end of the wizard.
            // Only clear the flag after the VM is guaranteed non-nil, so a nil
            // VM can't silently drop the request and permanently lose the flag.
            if shouldOpenRNodeWizard {
                if interfaceViewModel == nil {
                    let repo = interfaceRepository ?? InterfaceRepository()
                    interfaceRepository = repo
                    interfaceViewModel = InterfaceManagementViewModel(
                        repository: repo,
                        appServices: appServices
                    )
                }
                if let vm = interfaceViewModel {
                    vm.selectInterfaceType(.rnode)
                    shouldOpenRNodeWizard = false
                }
            }

            // Poll connection state every 2s so the card stays live
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await viewModel?.refreshConnectionState()
            }
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

    // MARK: - Advanced Section

    /// Section header above the Advanced cards (Transport Mode for now).
    /// Pure visual grouping — the cards below it are still independent
    /// `ExpandableSettingsCard`s, this just signals "you are leaving the
    /// common-toggles area".
    private var advancedSectionHeader: some View {
        HStack {
            Text("ADVANCED")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textSecondary)
                .tracking(0.5)
            Spacer()
        }
        .padding(.top, 16)
        .padding(.horizontal, 4)
    }

    // MARK: - Transport Mode Card

    private func transportModeCard(_ vm: SettingsViewModel) -> some View {
        ExpandableSettingsCard(
            icon: "point.3.connected.trianglepath.dotted",
            title: "Transport Mode",
            isExpanded: Binding(get: { vm.isTransportExpanded }, set: { vm.isTransportExpanded = $0 }),
            toggle: Binding(get: { vm.isTransportEnabled }, set: { newValue in
                vm.isTransportEnabled = newValue
                vm.saveSettings()
                // RNS reads `enable_transport` at Reticulum.__init__ time,
                // so we restart the Python backend to pick the new value
                // up — same path Settings → Manage Interfaces → Apply &
                // Restart uses. ~1-2s connectivity outage.
                Task {
                    await appServices.restartPythonBackend()
                }
            })
        ) {
            // Copy kept verbatim with Columba Android's AdvancedCard so the
            // two clients describe Transport Node identically. Update both
            // sides together if either changes.
            Text("Forward traffic for the mesh network. When disabled, this device will only handle its own traffic and won't relay messages for other peers. It's generally not recommended for mobile devices to be transport nodes. They are less likely to maintain a fixed position in the network, and thus can negatively impact multihop routing. Enabling this will increase data usage and battery drain. However, in a BLE-only mesh, it's required for multi-hop messaging.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Toggling restarts Reticulum (~1-2s offline).")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
    }

    #if ENABLE_NETWORK_EXTENSION
    // MARK: - Background Transport Card
    //
    // Currently compile-guarded off. The previous wiring tied each
    // toggle into reticulum-swift's `TCPInterface.beginTunnelMode` /
    // `endTunnelMode`, which routed outbound bytes through the
    // PacketTunnelProvider extension. The Python RNS migration deletes
    // that entire path (the Compat-layer TCPInterface has no tunnel
    // mode) and replaces it with rns_bridge.py's own socket. Bringing
    // background transport back means re-architecting the NE side to
    // either (a) drive Python's event loop from within the extension
    // (heavy — needs CPython embedded twice) or (b) re-wake the app
    // via BGProcessingTask + silent push when a peer announces and
    // immediately polls drain_events. Phase 2/3.

    @ViewBuilder
    private func backgroundTransportCard() -> some View {
        if let tunnel = appServices.tunnelManager {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accentColor)

                    Text("Background Transport")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { tunnel.isRunning },
                        set: { newValue in
                            Task {
                                if newValue {
                                    try? await tunnel.start()
                                } else {
                                    tunnel.stop()
                                }
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(Theme.accentColor)
                }

                Text("Keep TCP and LAN connections alive when the app is backgrounded. Enables receiving messages and notifications without opening the app.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(tunnel.isRunning ? Theme.success : Theme.textSecondary)
                        .frame(width: 8, height: 8)

                    Text(tunnel.isRunning ? "Running" : "Stopped")
                        .font(.caption)
                        .foregroundStyle(tunnel.isRunning ? Theme.success : Theme.textSecondary)
                }
            }
            .padding(16)
            .glassCard()
        }
    }
    #endif

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
                Text(vm.isNotificationsEnabled
                    ? "Manage notification preferences for messages, announces, and Bluetooth events."
                    : "All notifications are disabled. Enable to receive alerts for messages and events.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if vm.isNotificationsEnabled {
                    Divider()

                    // Presentation options
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

                    Divider()

                    Text("Notification Types")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    notificationTypeRow(
                        icon: "envelope.fill",
                        title: "Received Message",
                        description: "Notify when you receive a new message",
                        isOn: Binding(get: { vm.notifyReceivedMessage }, set: {
                            vm.notifyReceivedMessage = $0
                            vm.saveSettings()
                        })
                    )

                    notificationTypeRow(
                        icon: "star.fill",
                        title: "Message from Saved Peer",
                        description: "Only notify for messages from saved contacts",
                        isOn: Binding(get: { vm.notifyReceivedMessageFavorite }, set: {
                            vm.notifyReceivedMessageFavorite = $0
                            vm.saveSettings()
                        })
                    )

                    notificationTypeRow(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Heard Announce",
                        description: "Notify when you hear a new peer announce",
                        isOn: Binding(get: { vm.notifyHeardAnnounce }, set: {
                            vm.notifyHeardAnnounce = $0
                            vm.saveSettings()
                        })
                    )

                    if vm.notifyHeardAnnounce {
                        notificationTypeRow(
                            icon: "location.fill",
                            title: "Direct Only",
                            description: "Only direct (1-hop) announces",
                            isOn: Binding(get: { vm.notifyAnnounceDirectOnly }, set: {
                                vm.notifyAnnounceDirectOnly = $0
                                vm.saveSettings()
                            }),
                            indented: true
                        )

                        notificationTypeRow(
                            icon: "wifi.slash",
                            title: "Exclude TCP",
                            description: "Skip announces via TCP interfaces",
                            isOn: Binding(get: { vm.notifyAnnounceExcludeTcp }, set: {
                                vm.notifyAnnounceExcludeTcp = $0
                                vm.saveSettings()
                            }),
                            indented: true
                        )
                    }

                    notificationTypeRow(
                        icon: "antenna.radiowaves.left.and.right.circle.fill",
                        title: "BLE Peer Connected",
                        description: "Notify when a Bluetooth LE peer connects",
                        isOn: Binding(get: { vm.notifyBleConnected }, set: {
                            vm.notifyBleConnected = $0
                            vm.saveSettings()
                        })
                    )

                    notificationTypeRow(
                        icon: "antenna.radiowaves.left.and.right.slash",
                        title: "BLE Peer Disconnected",
                        description: "Notify when a Bluetooth LE peer disconnects",
                        isOn: Binding(get: { vm.notifyBleDisconnected }, set: {
                            vm.notifyBleDisconnected = $0
                            vm.saveSettings()
                        })
                    )
                }
            }
        }
    }

    private func notificationTypeRow(
        icon: String,
        title: String,
        description: String,
        isOn: Binding<Bool>,
        indented: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.accentColor)
        }
        .padding(.leading, indented ? 24 : 0)
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
            toggle: Binding(
                get: { vm.isLocationSharingEnabled },
                set: { newValue in
                    #if os(iOS)
                    if !newValue {
                        Task { await appServices.locationSharingManager?.stopAllSharing() }
                    }
                    #endif
                    vm.isLocationSharingEnabled = newValue
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Location sharing is started per-contact from conversations. Turning this off will immediately stop sharing with all contacts.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                HStack {
                    Text("Location Precision")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    Spacer()

                    Picker("", selection: Binding(
                        get: { vm.locationPrecisionRadius },
                        set: { vm.locationPrecisionRadius = $0; vm.saveSettings() }
                    )) {
                        Text("Precise").tag(0)
                        Text("Neighborhood (~100m)").tag(100)
                        Text("City (~1km)").tag(1000)
                        Text("Region (~10km)").tag(10000)
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accentColor)
                }

                HStack {
                    Text("Default Duration")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    Spacer()

                    Picker("", selection: Binding(
                        get: { vm.defaultSharingDuration },
                        set: { vm.defaultSharingDuration = $0; vm.saveSettings() }
                    )) {
                        ForEach(SharingDuration.allCases) { duration in
                            Text(duration.rawValue).tag(duration.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accentColor)
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
                settingsToggleRow(
                    title: "HTTP Map Tiles",
                    isOn: Binding(
                        get: { vm.mapHttpEnabled },
                        set: {
                            vm.mapHttpEnabled = $0
                            vm.saveSettings()
                        }
                    )
                )

                Text("When enabled, map tiles are fetched from OpenFreeMap via HTTP. When disabled, only downloaded offline maps are shown.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
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

}

// MARK: - Preview

// Note: Preview disabled - requires AppServices and SettingsRepository dependencies
// To preview, use the simulator with the full app.
