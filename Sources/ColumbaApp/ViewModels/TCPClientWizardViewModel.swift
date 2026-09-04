//
//  TCPClientWizardViewModel.swift
//  ColumbaApp
//
//  State management for the 2-step TCP client interface configuration wizard.
//  Mirrors the Android Columba TcpClientWizardViewModel.
//

import Foundation
import SwiftUI
import RNSAPI  // InterfaceMode / InterfaceEntity / InterfaceConfig live in RNSAPI on
              // this branch (they were app-module types on main). Not ReticulumSwift,
              // whose own InterfaceMode collided with RNSAPI's after the merge.

// MARK: - Wizard Step

/// Steps in the TCP client configuration wizard.
@available(iOS 17.0, macOS 14.0, *)
enum TCPClientWizardStep: Int, CaseIterable, Identifiable {
    case serverSelection = 0
    case reviewConfigure = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .serverSelection: return "Select Server"
        case .reviewConfigure: return "Review & Configure"
        }
    }
}

// MARK: - Parent Save Sink

/// Minimal protocol the wizard uses to forward a built TCP config to the
/// parent `InterfaceManagementViewModel`. Lets tests stub the parent without
/// pulling in repository / AppServices wiring.
@available(iOS 17.0, macOS 14.0, *)
protocol TCPClientWizardSaveSink: AnyObject {
    func saveTCPInterface(
        editing: InterfaceEntity?,
        name: String,
        enabled: Bool,
        mode: InterfaceMode,
        config: TCPClientConfig
    )
}

// MARK: - ViewModel

/// ViewModel for the TCP client configuration wizard.
///
/// Manages step navigation, server selection vs custom mode, edit-mode
/// pre-population, and forwards the built `TCPClientConfig` through a
/// `TCPClientWizardSaveSink` so the existing add/update path on
/// `InterfaceManagementViewModel` stays the single source of persistence.
@available(iOS 17.0, macOS 14.0, *)
@Observable
@MainActor
final class TCPClientWizardViewModel {

    // MARK: - Navigation

    var currentStep: TCPClientWizardStep = .serverSelection

    // MARK: - Step 1: Server Selection

    var selectedServer: TcpCommunityServer?
    var isCustomMode: Bool = false

    // MARK: - Step 2: Review & Configure

    var interfaceName: String = ""
    var targetHost: String = ""
    var targetPort: String = "4242"
    var networkName: String = ""
    var passphrase: String = ""
    var showPassphrase: Bool = false
    var mode: InterfaceMode = .full
    var enabled: Bool = true
    var showAdvanced: Bool = false
    /// Bootstrap-only: RNS auto-detaches this interface once discovered
    /// interfaces connect (RNS 1.1.x bootstrap semantics).
    var bootstrapOnly: Bool = false

    // MARK: - Edit Context

    /// The interface being edited (nil for create flow).
    private(set) var editingInterface: InterfaceEntity?

    /// Whether this wizard run is editing an existing interface.
    var isEditing: Bool { editingInterface != nil }

    // MARK: - Step 1 Actions

    /// Pre-fill name/host/port from a community server and clear custom mode.
    func selectServer(_ server: TcpCommunityServer) {
        selectedServer = server
        isCustomMode = false
        interfaceName = server.name
        targetHost = server.host
        targetPort = String(server.port)
    }

    /// Switch to custom-server mode: clear the selection and blank
    /// the name/host/port fields so the user types fresh values in step 2.
    func enableCustomMode() {
        selectedServer = nil
        isCustomMode = true
        interfaceName = ""
        targetHost = ""
        targetPort = ""
    }

    // MARK: - Edit Pre-population

    /// Populate fields from an existing TCP interface.
    ///
    /// If `(host, port)` matches a known `TcpCommunityServer`, that server
    /// is selected and the wizard opens at step 1. Otherwise the wizard opens
    /// at step 1 in custom mode so the user can confirm or change the entry.
    func loadExisting(_ entity: InterfaceEntity) {
        guard case .tcpClient(let config) = entity.config else { return }
        editingInterface = entity
        interfaceName = entity.name
        targetHost = config.targetHost
        targetPort = String(config.targetPort)
        networkName = config.networkName ?? ""
        passphrase = config.passphrase ?? ""
        mode = entity.mode
        enabled = entity.enabled
        bootstrapOnly = config.bootstrapOnly

        let match = TcpCommunityServer.servers.first { server in
            server.host == config.targetHost && server.port == config.targetPort
        }
        if let match = match {
            selectedServer = match
            isCustomMode = false
        } else {
            selectedServer = nil
            isCustomMode = true
        }
        currentStep = .serverSelection
    }

    // MARK: - Validation

    /// Whether the wizard can advance / save from the given step.
    func canProceed(from step: TCPClientWizardStep) -> Bool {
        switch step {
        case .serverSelection:
            return selectedServer != nil || isCustomMode
        case .reviewConfigure:
            let host = targetHost.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return false }
            guard let port = UInt16(targetPort.trimmingCharacters(in: .whitespaces)),
                  port > 0 else {
                return false
            }
            let trimmedName = interfaceName.trimmingCharacters(in: .whitespaces)
            return !trimmedName.isEmpty
        }
    }

    // MARK: - Step Navigation

    func goToReview() {
        currentStep = .reviewConfigure
    }

    func goToServerSelection() {
        currentStep = .serverSelection
    }

    // MARK: - Save

    /// Build the `TCPClientConfig` and forward it to the parent through the
    /// save sink. Persistence + apply-changes stay on the parent.
    func save(into sink: TCPClientWizardSaveSink) {
        let trimmedHost = targetHost.trimmingCharacters(in: .whitespaces)
        let port = UInt16(targetPort.trimmingCharacters(in: .whitespaces)) ?? 4242
        let trimmedNetwork = networkName.trimmingCharacters(in: .whitespaces)
        let trimmedPassphrase = passphrase.trimmingCharacters(in: .whitespaces)

        let config = TCPClientConfig(
            targetHost: trimmedHost,
            targetPort: port,
            networkName: trimmedNetwork.isEmpty ? nil : trimmedNetwork,
            passphrase: trimmedPassphrase.isEmpty ? nil : trimmedPassphrase,
            bootstrapOnly: bootstrapOnly
        )

        sink.saveTCPInterface(
            editing: editingInterface,
            name: interfaceName.trimmingCharacters(in: .whitespaces),
            enabled: enabled,
            mode: mode,
            config: config
        )
    }
}
