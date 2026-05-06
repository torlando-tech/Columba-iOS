//
//  TCPClientWizard.swift
//  ColumbaApp
//
//  2-step wizard for adding / editing a TCP client interface:
//  Server Selection (community list or custom) → Review & Configure.
//  Mirrors the Android Columba TcpClientWizardScreen.
//

import SwiftUI

// MARK: - Wizard Container

/// 2-step TCP client interface wizard.
@available(iOS 17.0, macOS 14.0, *)
struct TCPClientWizard: View {

    @Bindable var viewModel: InterfaceManagementViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var wizard = TCPClientWizardViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Step content
                    Group {
                        switch wizard.currentStep {
                        case .serverSelection:
                            TCPServerSelectionStep(wizard: wizard)
                        case .reviewConfigure:
                            TCPReviewConfigureStep(wizard: wizard)
                        }
                    }

                    bottomBar
                }
            }
            .navigationTitle(wizard.isEditing ? "Edit TCP Interface" : "Add TCP Interface")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        viewModel.dismissConfigSheet()
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
            }
            .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
        .onAppear {
            // Pre-populate when editing an existing interface.
            if let editing = viewModel.editingInterface,
               editing.type == .tcpClient,
               !wizard.isEditing {
                wizard.loadExisting(editing)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: wizard.currentStep)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if wizard.currentStep == .reviewConfigure {
                Button {
                    wizard.goToServerSelection()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(Theme.backgroundSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
            }

            stepIndicator

            Spacer()

            primaryActionButton
        }
        .padding(16)
        .background(Theme.backgroundPrimary)
    }

    private var stepIndicator: some View {
        Text("\(wizard.currentStep.rawValue + 1) of \(TCPClientWizardStep.allCases.count)")
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.textSecondary)
    }

    private var primaryActionButton: some View {
        Button {
            switch wizard.currentStep {
            case .serverSelection:
                wizard.goToReview()
            case .reviewConfigure:
                wizard.save(into: viewModel)
            }
        } label: {
            HStack(spacing: 6) {
                Text(wizard.currentStep == .reviewConfigure ? (wizard.isEditing ? "Update" : "Save") : "Next")
                if wizard.currentStep == .serverSelection {
                    Image(systemName: "chevron.right")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background(wizard.canProceed(from: wizard.currentStep) ? Theme.accentColor : Theme.textDisabled)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        }
        .disabled(!wizard.canProceed(from: wizard.currentStep))
    }
}

// MARK: - Step 1: Server Selection

@available(iOS 17.0, macOS 14.0, *)
struct TCPServerSelectionStep: View {

    @Bindable var wizard: TCPClientWizardViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose a public Reticulum transport node, or set up a custom server.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)

                // Community servers. Reticulum-Swift does not yet support
                // bootstrap interfaces, so all servers share a single section.
                if !TcpCommunityServer.servers.isEmpty {
                    sectionHeader("Community Servers")
                    VStack(spacing: 8) {
                        ForEach(TcpCommunityServer.servers) { server in
                            serverRow(server)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                sectionHeader("Custom")
                customRow
                    .padding(.horizontal, 16)

                Spacer(minLength: 24)
            }
            .padding(.top, 12)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 16)
    }

    private func serverRow(_ server: TcpCommunityServer) -> some View {
        Button {
            wizard.selectServer(server)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(server.address)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                if wizard.selectedServer?.id == server.id && !wizard.isCustomMode {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accentColor)
                }
            }
            .padding(14)
            .background(rowBackground(selected: wizard.selectedServer?.id == server.id && !wizard.isCustomMode))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        }
        .buttonStyle(.plain)
    }

    private var customRow: some View {
        Button {
            wizard.enableCustomMode()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(Theme.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Server")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Enter your own host and port")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                if wizard.isCustomMode {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accentColor)
                }
            }
            .padding(14)
            .background(rowBackground(selected: wizard.isCustomMode))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        }
        .buttonStyle(.plain)
    }

    private func rowBackground(selected: Bool) -> some View {
        ZStack {
            Theme.backgroundSecondary
            if selected {
                Theme.accentColor.opacity(0.12)
            }
        }
    }
}

// MARK: - Step 2: Review & Configure

@available(iOS 17.0, macOS 14.0, *)
struct TCPReviewConfigureStep: View {

    @Bindable var wizard: TCPClientWizardViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                serverSummaryCard
                interfaceFields
                enabledToggle
                advancedSection
            }
            .padding(16)
        }
    }

    private var serverSummaryCard: some View {
        HStack(spacing: 12) {
            Image(systemName: wizard.isCustomMode ? "slider.horizontal.3" : "globe")
                .font(.title2)
                .foregroundStyle(Theme.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(wizard.isCustomMode ? "Custom Server" : (wizard.selectedServer?.name ?? "—"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let server = wizard.selectedServer, !wizard.isCustomMode {
                    Text(server.address)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Enter host and port below")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    private var interfaceFields: some View {
        VStack(spacing: 16) {
            field(
                title: "Interface Name",
                placeholder: "e.g., Beleth RNS Hub",
                text: $wizard.interfaceName
            )

            field(
                title: "Target Host",
                placeholder: "IP address or hostname",
                text: $wizard.targetHost
            )

            field(
                title: "Target Port",
                placeholder: "4242",
                text: $wizard.targetPort,
                isNumeric: true
            )
        }
    }

    private var enabledToggle: some View {
        HStack {
            Text("Enabled")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Toggle("", isOn: $wizard.enabled)
                .labelsHidden()
                .tint(Theme.accentColor)
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    private var advancedSection: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    wizard.showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Text("Advanced Options")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: wizard.showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            }

            if wizard.showAdvanced {
                VStack(spacing: 16) {
                    field(
                        title: "Network Name (optional)",
                        placeholder: "Virtual network name",
                        text: $wizard.networkName
                    )

                    passphraseField

                    modePicker
                }
                .padding(16)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var passphraseField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Passphrase (optional)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            HStack {
                if wizard.showPassphrase {
                    TextField("Authentication passphrase", text: $wizard.passphrase)
                        .textFieldStyle(.plain)
                } else {
                    SecureField("Authentication passphrase", text: $wizard.passphrase)
                        .textFieldStyle(.plain)
                }

                Button {
                    wizard.showPassphrase.toggle()
                } label: {
                    Image(systemName: wizard.showPassphrase ? "eye.slash" : "eye")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(12)
            .background(Theme.backgroundPrimary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
            #if os(iOS)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            #endif

            Text("Optional: Sets an authentication passphrase on the interface.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Interface Mode")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            Picker("Mode", selection: $wizard.mode) {
                ForEach(InterfaceMode.allCases, id: \.self) { mode in
                    Text("\(mode.displayName) - \(mode.description)")
                        .tag(mode)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accentColor)
        }
    }

    private func field(
        title: String,
        placeholder: String,
        text: Binding<String>,
        isNumeric: Bool = false
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
                .keyboardType(isNumeric ? .numberPad : .default)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
        }
    }
}
