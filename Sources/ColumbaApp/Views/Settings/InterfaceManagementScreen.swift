//
//  InterfaceManagementScreen.swift
//  ColumbaApp
//
//  Screen for managing Reticulum network interfaces.
//  Shows list of configured interfaces with add/edit/delete capabilities.
//

import SwiftUI

/// Main screen for managing network interfaces.
///
/// Features:
/// - Summary card showing enabled/total counts
/// - List of interface cards with status, edit, delete
/// - FAB to add new interfaces
/// - Type selector sheet for new interfaces
/// - Config sheet for add/edit
@available(iOS 17.0, macOS 14.0, *)
struct InterfaceManagementScreen: View {

    // MARK: - Dependencies

    @Bindable var viewModel: InterfaceManagementViewModel

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        ZStack {
            // Background
            Theme.backgroundPrimary
                .ignoresSafeArea()

            // Content
            ScrollView {
                VStack(spacing: 16) {
                    // Summary Card
                    summaryCard

                    // Interfaces List
                    if viewModel.interfaces.isEmpty {
                        emptyStateView
                    } else {
                        interfacesList
                    }
                }
                .padding(16)
            }
            // FAB bottom inset — scroll content stays clear of the FAB
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    addButton
                }
                .padding(16)
            }
            // Toast top inset — appears above scroll content, respects nav bar
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if let error = viewModel.errorMessage {
                        messageCard(error, isError: true)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                    if let success = viewModel.successMessage {
                        messageCard(success, isError: false)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
                .animation(.easeInOut, value: viewModel.errorMessage)
                .animation(.easeInOut, value: viewModel.successMessage)
            }
        }
        .navigationTitle("Network Interfaces")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.hasPendingChanges {
                    Button {
                        Task {
                            await viewModel.applyChanges()
                        }
                    } label: {
                        if viewModel.isApplyingChanges {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Apply")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(viewModel.isApplyingChanges)
                }
            }
        }
        .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .sheet(isPresented: $viewModel.showTypeSelector) {
            InterfaceTypeSelector(viewModel: viewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.showConfigSheet) {
            Group {
                if viewModel.configType == .autoInterface {
                    AutoInterfaceConfigSheet(viewModel: viewModel)
                } else if viewModel.configType == .ble {
                    BLEInterfaceConfigSheet(viewModel: viewModel)
                } else {
                    TCPInterfaceConfigSheet(viewModel: viewModel)
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert("Delete Interface?", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                viewModel.interfaceToDelete = nil
            }
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete()
            }
        } message: {
            if let interface = viewModel.interfaceToDelete {
                Text("Are you sure you want to delete \"\(interface.name)\"? This action cannot be undone.")
            }
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        HStack(spacing: 32) {
            VStack(spacing: 4) {
                Text("\(viewModel.enabledCount)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accentColor)

                Text("Enabled")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 4) {
                Text("\(viewModel.totalCount)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                Text("Total")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge))
    }

    // MARK: - Interfaces List

    private var interfacesList: some View {
        VStack(spacing: 12) {
            ForEach(viewModel.interfaces) { interface in
                InterfaceCard(
                    interface: interface,
                    status: viewModel.getStatus(for: interface),
                    onToggle: { enabled in
                        viewModel.toggleInterface(interface, enabled: enabled)
                    },
                    onEdit: {
                        viewModel.showEditInterface(interface)
                    },
                    onDelete: {
                        viewModel.interfaceToDelete = interface
                        viewModel.showDeleteConfirmation = true
                    }
                )
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textSecondary)

            Text("No Interfaces Configured")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Tap + to add your first network interface")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Add Button (FAB)

    private var addButton: some View {
        Button {
            viewModel.showAddInterface()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Theme.accentColor)
                .clipShape(Circle())
                .shadow(color: Theme.accentColor.opacity(0.4), radius: 8, y: 4)
        }
    }

    // MARK: - Message Card

    private func messageCard(_ message: String, isError: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Theme.error : Theme.success)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)

            Spacer()
        }
        .padding(16)
        .background(isError ? Theme.error.opacity(0.15) : Theme.success.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }
}

// MARK: - Interface Card

/// Card component for displaying a single interface.
@available(iOS 17.0, macOS 14.0, *)
struct InterfaceCard: View {

    let interface: InterfaceEntity
    let status: InterfaceStatus
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(interface.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    Text(interface.type.displayName)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { interface.enabled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .tint(Theme.accentColor)
            }

            // Connection details
            if case .tcpClient(let config) = interface.config {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.caption)
                    Text(verbatim: "\(config.targetHost):\(config.targetPort)")
                        .font(.caption.monospaced())
                }
                .foregroundStyle(Theme.textSecondary)
            } else if case .autoInterface(let config) = interface.config {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                    Text("Group: \(config.groupId ?? "reticulum")")
                        .font(.caption.monospaced())
                }
                .foregroundStyle(Theme.textSecondary)
            } else if case .ble = interface.config {
                HStack(spacing: 4) {
                    Image(systemName: "wave.3.right")
                        .font(.caption)
                    Text("Bluetooth LE peer-to-peer")
                        .font(.caption.monospaced())
                }
                .foregroundStyle(Theme.textSecondary)
            } else if case .rnode(let config) = interface.config {
                HStack(spacing: 4) {
                    Image(systemName: "radio")
                        .font(.caption)
                    Text("\(config.deviceName) @ \(config.frequency / 1_000_000) MHz")
                        .font(.caption.monospaced())
                }
                .foregroundStyle(Theme.textSecondary)
            }

            // Status row
            HStack(spacing: 8) {
                // Status badge
                statusBadge

                Spacer()

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        onEdit()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("Edit")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accentColor)
                    }

                    Button {
                        onDelete()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Delete")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.error)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(interface.enabled ? status.displayName.uppercased() : "DISABLED")
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statusColor: Color {
        guard interface.enabled else {
            return Theme.textSecondary
        }

        switch status {
        case .connected: return Theme.success
        case .connecting, .reconnecting: return .orange
        case .disconnected: return Theme.textSecondary
        case .error: return Theme.error
        }
    }
}

// MARK: - Interface Type Selector

/// Sheet for selecting interface type when adding new interface.
@available(iOS 17.0, macOS 14.0, *)
struct InterfaceTypeSelector: View {

    @Bindable var viewModel: InterfaceManagementViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundPrimary
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    typeOption(
                        type: .tcpClient,
                        highlighted: true
                    )

                    typeOption(
                        type: .autoInterface,
                        highlighted: true
                    )

                    typeOption(
                        type: .ble,
                        highlighted: true
                    )

                    typeOption(
                        type: .rnode,
                        highlighted: true
                    )
                }
                .padding(16)
            }
            .navigationTitle("Select Interface Type")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
    }

    private func typeOption(type: InterfaceType, highlighted: Bool = false) -> some View {
        Button {
            dismiss()
            viewModel.selectInterfaceType(type)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: type.icon)
                    .font(.title2)
                    .foregroundStyle(highlighted ? Theme.accentColor : Theme.textSecondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(type.displayName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    Text(type.description)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .background(highlighted ? Theme.accentColor.opacity(0.1) : Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        }
    }
}

// MARK: - TCP Interface Config Sheet

/// Sheet for configuring TCP client interface.
@available(iOS 17.0, macOS 14.0, *)
struct TCPInterfaceConfigSheet: View {

    @Bindable var viewModel: InterfaceManagementViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showAdvanced: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundPrimary
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Interface Name
                        configField(
                            title: "Interface Name",
                            placeholder: "e.g., Home Server",
                            text: $viewModel.configName,
                            error: viewModel.nameError
                        )

                        // Target Host (TCP Client)
                        if viewModel.configType == .tcpClient {
                            configField(
                                title: "Target Host",
                                placeholder: "IP address or hostname",
                                text: $viewModel.configTargetHost,
                                error: viewModel.targetHostError,
                                keyboardType: .URL
                            )

                            configField(
                                title: "Target Port",
                                placeholder: "4242",
                                text: $viewModel.configTargetPort,
                                error: viewModel.targetPortError,
                                keyboardType: .numberPad
                            )
                        }

                        // Enabled Toggle
                        HStack {
                            Text("Enabled")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)

                            Spacer()

                            Toggle("", isOn: $viewModel.configEnabled)
                                .labelsHidden()
                                .tint(Theme.accentColor)
                        }
                        .padding(16)
                        .background(Theme.backgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))

                        // Advanced Options
                        advancedSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle(viewModel.isEditing ? "Edit Interface" : "Add Interface")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        viewModel.dismissConfigSheet()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isEditing ? "Update" : "Add") {
                        viewModel.saveInterface()
                    }
                    .fontWeight(.semibold)
                    .disabled(!viewModel.isFormValid)
                }
            }
            .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
    }

    // MARK: - Config Field

    private func configField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        error: String? = nil,
        keyboardType: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
                .foregroundStyle(Theme.textPrimary)
                #if os(iOS)
                .keyboardType(keyboardType)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif

            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.error)
            }
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        VStack(spacing: 12) {
            // Expand/Collapse Button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Text("Advanced Options")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer()

                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            }

            if showAdvanced {
                VStack(spacing: 16) {
                    // Network Name (IFAC)
                    configField(
                        title: "Network Name (optional)",
                        placeholder: "Virtual network name",
                        text: $viewModel.configNetworkName
                    )

                    // Passphrase (IFAC)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Passphrase (optional)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)

                        HStack {
                            if viewModel.configShowPassphrase {
                                TextField("Authentication passphrase", text: $viewModel.configPassphrase)
                                    .textFieldStyle(.plain)
                            } else {
                                SecureField("Authentication passphrase", text: $viewModel.configPassphrase)
                                    .textFieldStyle(.plain)
                            }

                            Button {
                                viewModel.configShowPassphrase.toggle()
                            } label: {
                                Image(systemName: viewModel.configShowPassphrase ? "eye.slash" : "eye")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(12)
                        .background(Theme.backgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        #endif

                        Text("Optional: Sets an authentication passphrase on the interface.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // Interface Mode
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Interface Mode")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)

                        Picker("Mode", selection: $viewModel.configMode) {
                            ForEach(InterfaceMode.allCases, id: \.self) { mode in
                                Text("\(mode.displayName) - \(mode.description)")
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.accentColor)
                    }
                }
                .padding(16)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Auto Interface Config Sheet

/// Sheet for configuring Auto Discovery interface.
@available(iOS 17.0, macOS 14.0, *)
struct AutoInterfaceConfigSheet: View {

    @Bindable var viewModel: InterfaceManagementViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundPrimary
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Interface Name
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Interface Name")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)

                            TextField("e.g., LAN Discovery", text: $viewModel.configName)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(Theme.backgroundSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
                                .foregroundStyle(Theme.textPrimary)
                                #if os(iOS)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                #endif

                            if let error = viewModel.nameError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(Theme.error)
                            }
                        }

                        // Group ID
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Group ID")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)

                            TextField("reticulum", text: $viewModel.configAutoGroupId)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(Theme.backgroundSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
                                .foregroundStyle(Theme.textPrimary)
                                #if os(iOS)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                #endif

                            Text("Peers must share the same group ID to discover each other. Default: \"reticulum\"")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        // Enabled Toggle
                        HStack {
                            Text("Enabled")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)

                            Spacer()

                            Toggle("", isOn: $viewModel.configEnabled)
                                .labelsHidden()
                                .tint(Theme.accentColor)
                        }
                        .padding(16)
                        .background(Theme.backgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))

                        // Info card
                        VStack(alignment: .leading, spacing: 8) {
                            Label("How Auto Discovery Works", systemImage: "info.circle")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.accentColor)

                            Text("Auto Discovery uses IPv6 link-local multicast to find other Reticulum nodes on your local network. No manual IP configuration needed.")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)

                            Text("Peers on the same WiFi or Ethernet network will automatically discover each other and exchange messages directly.")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(16)
                        .background(Theme.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                    }
                    .padding(16)
                }
            }
            .navigationTitle(viewModel.isEditing ? "Edit Auto Discovery" : "Add Auto Discovery")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        viewModel.dismissConfigSheet()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isEditing ? "Update" : "Add") {
                        viewModel.saveInterface()
                    }
                    .fontWeight(.semibold)
                    .disabled(!viewModel.isFormValid)
                }
            }
            .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
    }
}

// MARK: - BLE Interface Config Sheet

/// Sheet for configuring BLE interface.
@available(iOS 17.0, macOS 14.0, *)
struct BLEInterfaceConfigSheet: View {

    @Bindable var viewModel: InterfaceManagementViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundPrimary
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Interface Name
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Interface Name")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)

                            TextField("e.g., BLE Peers", text: $viewModel.configName)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(Theme.backgroundSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
                                .foregroundStyle(Theme.textPrimary)
                                #if os(iOS)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                #endif

                            if let error = viewModel.nameError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(Theme.error)
                            }
                        }

                        // Enabled Toggle
                        HStack {
                            Text("Enabled")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)

                            Spacer()

                            Toggle("", isOn: $viewModel.configEnabled)
                                .labelsHidden()
                                .tint(Theme.accentColor)
                        }
                        .padding(16)
                        .background(Theme.backgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))

                        // Info card
                        VStack(alignment: .leading, spacing: 8) {
                            Label("How BLE Works", systemImage: "info.circle")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.accentColor)

                            Text("BLE creates a peer-to-peer Bluetooth Low Energy network between nearby devices running Reticulum. No internet or WiFi required.")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)

                            Text("Devices automatically discover, connect, and exchange packets over BLE GATT. Up to 7 simultaneous peer connections.")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)

                            Text("Range is typically 10-30 meters depending on environment and device.")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(16)
                        .background(Theme.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                    }
                    .padding(16)
                }
            }
            .navigationTitle(viewModel.isEditing ? "Edit BLE" : "Add BLE")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        viewModel.dismissConfigSheet()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isEditing ? "Update" : "Add") {
                        viewModel.saveInterface()
                    }
                    .fontWeight(.semibold)
                    .disabled(!viewModel.isFormValid)
                }
            }
            .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
    }
}
