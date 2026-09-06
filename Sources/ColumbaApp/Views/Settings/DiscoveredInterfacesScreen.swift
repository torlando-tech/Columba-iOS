//
//  DiscoveredInterfacesScreen.swift
//  ColumbaApp
//
//  Screen for interfaces discovered via RNS 1.1.x interface discovery
//  (issue #193). Mirrors the Android DiscoveredInterfacesScreen layout:
//  discovery settings card, status summary, sort/search/type-chip/IFAC
//  display filters, and one card per discovered interface with type
//  details, location (tap to open in Maps), and an expandable
//  "all announced fields" section.
//
//  Every sub-view is a separate private struct (not inlined into the
//  screen body) to keep the SwiftUI type-checker fast. All control
//  bindings route through the view model's intent methods
//  (toggleDiscovery / setAutoconnectCount / setSortMode /
//  setSearchQuery / toggleTypeFilter / toggleIfacOnlyFilter /
//  clearFilters) — the view never writes VM state directly.
//

import SwiftUI
import MapKit
import RNSAPI
#if canImport(UIKit)
import UIKit
#endif

/// Screen showing interfaces announced by other RNS nodes, with the
/// discovery + auto-connect settings and display filters.
@available(iOS 17.0, macOS 14.0, *)
struct DiscoveredInterfacesScreen: View {

    // MARK: - Dependencies

    @Bindable var viewModel: DiscoveredInterfacesViewModel
    let appServices: AppServices
    /// Shared InterfaceRepository (issue #193). The sheet wizard VMs are
    /// built on this instance — NOT a fresh one — so a save appends to the
    /// same @Observable `interfaces` array the Interfaces list (and IMS)
    /// reads, keeping the list fresh after "Add to Config" without a
    /// relaunch. Fallback to a fresh repo when the caller has none.
    var interfaceRepository: InterfaceRepository?

    // MARK: - Card action state (issue #193)

    /// Wizard VM for the "Add to Config" sheet — the sheet owns its own
    /// InterfaceManagementViewModel (the house save sink) so the wizard's
    /// unchanged save/cancel paths persist + close it.
    @State private var tcpInterfaceViewModel: InterfaceManagementViewModel?
    @State private var tcpPrefill: DiscoveredInterface?

    /// Wizard VM for the "Use for RNode" sheet (same pattern as TCP).
    @State private var rnodeInterfaceViewModel: InterfaceManagementViewModel?
    @State private var rnodePrefill: DiscoveredInterface?

    /// ID of the card whose "Copy LoRa Params" just fired (brief checkmark).
    @State private var copiedCardID: String?

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                DiscoverySettingsCard(vm: viewModel)

                if !viewModel.originalInterfaces.isEmpty {
                    DiscoveryStatusSummary(vm: viewModel)
                    DiscoveredSortFilterBar(vm: viewModel)

                    if viewModel.interfaces.isEmpty {
                        NoFilterMatchesCard(onClear: { viewModel.clearFilters() })
                    } else {
                        ForEach(viewModel.interfaces) { iface in
                            discoveredCard(for: iface)
                        }
                    }
                } else if !viewModel.isLoading {
                    EmptyDiscoveredCard()
                }
            }
            .padding(16)
        }
        .navigationTitle(String(localized: "Discovered Interfaces"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
            if viewModel.isRestarting {
                RestartingOverlay()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("discovery_refresh")
            }
        }
        .onAppear {
            viewModel.load()
            viewModel.requestUserLocation()   // no-op unless already authorized
        }
        // Card action sheets (issue #193): each sheet is driven by a
        // sheet-owned InterfaceManagementViewModel (the house save sink),
        // presented through the VM's own wizard flags with the same
        // Binding(get:set:) pattern SettingsView uses for the RNode wizard.
        .sheet(
            isPresented: Binding(
                get: { tcpInterfaceViewModel?.showTCPWizard ?? false },
                // Forward (house RNode-cover pattern, SettingsView:211) so
                // swipe-to-dismiss actually flips the flag and triggers
                // onDismiss cleanup instead of snapping back.
                set: { _ in
                    tcpInterfaceViewModel?.showTCPWizard = false
                }
            ),
            onDismiss: {
                // Match the house wizard sheets (IMS:162, SettingsView RNode)
                // exactly: dismissConfigSheet() resets the flags + form. Do
                // NOT apply here — the save paths already do it where the
                // house does (saveTCPInterface spawns its own applyChanges
                // Task; Python RNode deliberately waits for the explicit
                // Apply step), and applying in onDismiss would race/double
                // that apply.
                tcpInterfaceViewModel?.dismissConfigSheet()
                tcpInterfaceViewModel = nil
                tcpPrefill = nil
            }
        ) {
            if let imvm = tcpInterfaceViewModel {
                TCPClientWizard(viewModel: imvm, prefill: tcpPrefill)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        #if os(iOS) && COLUMBA_RNODE_ENABLED
        .sheet(
            isPresented: Binding(
                get: { rnodeInterfaceViewModel?.showRNodeWizard ?? false },
                // Forward (house RNode-cover pattern, SettingsView:211) so
                // swipe-to-dismiss actually flips the flag and triggers
                // onDismiss cleanup instead of snapping back.
                set: { _ in
                    rnodeInterfaceViewModel?.showRNodeWizard = false
                }
            ),
            onDismiss: {
                // RNode differs from TCP here: saveInterface() on Python
                // STAGES the change (hasPendingChanges) but deliberately
                // does not auto-apply (IMVM:407-411 — "the user taps Apply
                // explicitly"), and applyRNodeLiveChange is a Model-B-only
                // no-op on Python (IMVM:470). The house Apply button lives in
                // the IMS toolbar, which is NOT reachable from this sheet —
                // so without an apply here the staged Python change is
                // persisted but never pushed to the live stack. TCP does NOT
                // get this: saveTCPInterface already spawns its own
                // applyChanges Task (IMVM:452), so a second would race it.
                // Model B is safe: applyInterfaceChanges is a no-op there
                // and the radio is already live via applyRNodeLiveChange.
                let vm = rnodeInterfaceViewModel
                rnodeInterfaceViewModel?.dismissConfigSheet()
                if let vm, vm.hasPendingChanges {
                    Task { @MainActor in await vm.applyChanges() }
                }
                rnodeInterfaceViewModel = nil
                rnodePrefill = nil
            }
        ) {
            if let imvm = rnodeInterfaceViewModel {
                RNodeWizardView(viewModel: imvm, prefill: rnodePrefill)
            }
        }
        #endif
    }

    /// One discovered-interface card (extracted from `body` so the
    /// ForEach expression stays inside the type-checker's complexity
    /// budget — same fix as ImageQualityPickerSheet, issue #181).
    private func discoveredCard(for iface: DiscoveredInterface) -> some View {
        DiscoveredInterfaceCard(
            iface: iface,
            distanceKm: viewModel.calculateDistance(iface),
            isConnected: viewModel.isAutoconnected(iface),
            onAddToConfig: { card in addToConfig(card) },
            onCopyLoRaParams: { card in copyLoRaParams(card) },
            onUseForRNode: { card in useForRNode(card) },
            justCopied: copiedCardID == iface.id
        )
    }

    // MARK: - Card actions (issue #193)

    /// "Add to Config": prefill the TCP client wizard with the announced
    /// host/port/IFAC fields, landing directly on the review step. The sheet
    /// is driven by the IMVM's own `showTCPWizard` flag (house pattern), and
    /// the wizard view seeds itself from `prefill` in `onAppear`.
    private func addToConfig(_ iface: DiscoveredInterface) {
        let imvm = tcpInterfaceViewModel ?? InterfaceManagementViewModel(
            repository: interfaceRepository ?? InterfaceRepository(),
            appServices: appServices
        )
        tcpInterfaceViewModel = imvm
        tcpPrefill = iface
        // Fresh create-flow state (mirror dismissConfigSheet's resets without
        // touching the wizard flag).
        imvm.editingInterface = nil
        imvm.configName = ""
        imvm.configType = .tcpClient
        imvm.configEnabled = true
        imvm.configMode = .full
        imvm.showTCPWizard = true
    }

    /// "Copy LoRa Params": publish the announced radio parameters to the
    /// pasteboard and flash a checkmark on the card that fired.
    private func copyLoRaParams(_ iface: DiscoveredInterface) {
        #if canImport(UIKit)
        UIPasteboard.general.string = formatLoraParamsForClipboard(iface)
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formatLoraParamsForClipboard(iface), forType: .string)
        #endif
        copiedCardID = iface.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedCardID == iface.id { copiedCardID = nil }
        }
    }

    /// "Use for RNode": prefill the RNode wizard's custom LoRa fields from
    /// the announced parameters (the device is still selected in-wizard, as
    /// with the normal RNode flow).
    #if os(iOS) && COLUMBA_RNODE_ENABLED
    private func useForRNode(_ iface: DiscoveredInterface) {
        let imvm = rnodeInterfaceViewModel ?? InterfaceManagementViewModel(
            repository: interfaceRepository ?? InterfaceRepository(),
            appServices: appServices
        )
        rnodeInterfaceViewModel = imvm
        rnodePrefill = iface
        imvm.editingInterface = nil
        imvm.configName = ""
        imvm.configType = .rnode
        imvm.configEnabled = true
        imvm.configMode = .full
        imvm.showRNodeWizard = true
    }
    #else
    private func useForRNode(_ iface: DiscoveredInterface) {}
    #endif
}

// MARK: - Discovery Settings Card

/// Card with the discovery master switch, the auto-connect count slider,
/// and the bootstrap-interface list. Toggling fires the VM's intent
/// methods — the VM owns the persist + in-process restart flow.
@available(iOS 17.0, macOS 14.0, *)
private struct DiscoverySettingsCard: View {

    @Bindable var vm: DiscoveredInterfacesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row: status dot + title/subtitle
            HStack(spacing: 8) {
                Circle()
                    .fill(vm.isDiscoveryEnabled ? Theme.success : Theme.textSecondary)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Interface Discovery"))
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Toggle(String(localized: "Enable discovery"), isOn: discoveryBinding)
                    .labelsHidden()
                    .tint(Theme.accentColor)
                    .accessibilityIdentifier("discovery_toggle")
            }

            // Info text
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                Text(String(localized: "Discovers interfaces announced by other RNS nodes. Changes apply after a brief restart of Reticulum."))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            // Auto-connect count slider (only when discovery is enabled)
            if vm.discoverInterfacesEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(autoConnectTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)

                        Spacer()

                        Text(vm.autoconnectCount == 0
                             ? String(localized: "Off")
                             : "\(vm.autoconnectCount)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.accentColor)
                    }

                    Slider(value: autoconnectBinding, in: 0...10, step: 1)
                        .tint(Theme.accentColor)
                }
            }

            // Bootstrap interfaces (they enable discovery)
            if !vm.bootstrapInterfaceNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Bootstrap interfaces"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)

                    ForEach(vm.bootstrapInterfaceNames, id: \.self) { name in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.textSecondary)
                                .frame(width: 6, height: 6)
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    Text(String(localized: "These auto-detach once discovered interfaces connect."))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    // MARK: - Bindings (fire VM intent methods, never write VM state)

    private var discoveryBinding: Binding<Bool> {
        Binding(
            get: { vm.discoverInterfacesEnabled },
            set: { _ in vm.toggleDiscovery() }
        )
    }

    private var autoconnectBinding: Binding<Double> {
        Binding(
            get: { Double(vm.autoconnectCount) },
            set: { vm.setAutoconnectCount(Int($0.rounded())) }
        )
    }

    // MARK: - Derived

    private var subtitle: String {
        if vm.isRestarting {
            return String(localized: "Restarting…")
        }
        return vm.isDiscoveryEnabled
            ? String(localized: "Active – discovering interfaces")
            : String(localized: "Disabled")
    }

    private var autoConnectTitle: String {
        String(format: String(localized: "Auto-connect up to %lld discovered interfaces"), Int64(vm.autoconnectCount))
    }
}

// MARK: - Status Summary

/// "N discovered" total with available / unknown / stale badges.
/// Counts reflect ALL discovered interfaces (not the filtered list).
@available(iOS 17.0, macOS 14.0, *)
private struct DiscoveryStatusSummary: View {

    @Bindable var vm: DiscoveredInterfacesViewModel

    var body: some View {
        HStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("\(vm.originalInterfaces.count)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(String(localized: "Discovered"))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            statusBadge(String(localized: "Available"), count: vm.availableCount, color: Theme.success)
            statusBadge(String(localized: "Unknown"), count: vm.unknownCount, color: Theme.textSecondary)
            statusBadge(String(localized: "Stale"), count: vm.staleCount, color: .orange)
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    private func statusBadge(_ label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Sort / Search / Filter Bar

/// Segmented sort control, search field, type chips (TCP / Radio / I2P /
/// Other), the IFAC-only display filter, and the "N of M" + clear row.
@available(iOS 17.0, macOS 14.0, *)
private struct DiscoveredSortFilterBar: View {

    @Bindable var vm: DiscoveredInterfacesViewModel

    var body: some View {
        VStack(spacing: 10) {
            Picker(String(localized: "Sort"), selection: sortBinding) {
                Text(String(localized: "Quality")).tag(DiscoveredSortMode.availabilityAndQuality)
                Text(String(localized: "Nearest"))
                    .tag(DiscoveredSortMode.proximity)
                    .disabled(!hasUserLocation)
            }
            .pickerStyle(.segmented)

            TextField(
                String(localized: "Search interfaces…"),
                text: searchBinding,
                prompt: Text(String(localized: "Search interfaces…"))
            )
            .textFieldStyle(.roundedBorder)
            .font(.subheadline)
            .accessibilityIdentifier("discovery_search")

            HStack(spacing: 8) {
                ForEach(DiscoveredTypeFilter.allCases) { filter in
                    typeChip(filter)
                }

                Spacer(minLength: 0)

                Button {
                    vm.toggleIfacOnlyFilter()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: vm.ifacOnly ? "lock.fill" : "lock")
                            .font(.caption)
                        Text(String(localized: "IFAC only"))
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(vm.ifacOnly ? Theme.accentColor : Theme.backgroundPrimary)
                    .foregroundStyle(vm.ifacOnly ? .white : Theme.textSecondary)
                    .overlay(
                        Capsule().stroke(vm.ifacOnly ? Color.clear : Theme.textSecondary.opacity(0.4), lineWidth: 1)
                    )
                    .clipShape(Capsule())
                }
                .accessibilityIdentifier("discovery_ifac_only")
            }

            if hasActiveFilters {
                HStack {
                    Text(String(format: String(localized: "%lld of %lld"), Int64(vm.interfaces.count), Int64(vm.originalInterfaces.count)))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button(String(localized: "Clear")) {
                        vm.clearFilters()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentColor)
                    .accessibilityIdentifier("discovery_clear_filters")
                }
            }
        }
        .padding(12)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    // MARK: - Bindings (fire VM intent methods, never write VM state)

    private var sortBinding: Binding<DiscoveredSortMode> {
        Binding(
            get: { vm.sortMode },
            set: { vm.setSortMode($0) }
        )
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { vm.searchQuery },
            set: { vm.setSearchQuery($0) }
        )
    }

    // MARK: - Chips + state

    private func typeChip(_ filter: DiscoveredTypeFilter) -> some View {
        let selected = vm.typeFilters.contains(filter)
        return Button {
            vm.toggleTypeFilter(filter)
        } label: {
            Text(filter.rawValue)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Theme.accentColor : Theme.backgroundPrimary)
                .foregroundStyle(selected ? .white : Theme.textSecondary)
                .overlay(
                    Capsule().stroke(selected ? Color.clear : Theme.textSecondary.opacity(0.4), lineWidth: 1)
                )
                .clipShape(Capsule())
        }
    }

    private var hasUserLocation: Bool {
        vm.userLatitude != nil && vm.userLongitude != nil
    }

    private var hasActiveFilters: Bool {
        !vm.searchQuery.isEmpty || !vm.typeFilters.isEmpty || vm.ifacOnly
    }
}

// MARK: - Discovered Interface Card

/// Card for a single discovered interface: header (icon, name, type),
/// status/connected badges, transport id, type-specific details, IFAC
/// row, location (tappable), last heard + hops, and the expandable
/// all-announced-fields section.
@available(iOS 17.0, macOS 14.0, *)
private struct DiscoveredInterfaceCard: View {

    let iface: DiscoveredInterface
    let distanceKm: Double?
    let isConnected: Bool

    /// Card action handlers (issue #193) — the screen owns the sheets.
    var onAddToConfig: (DiscoveredInterface) -> Void
    var onCopyLoRaParams: (DiscoveredInterface) -> Void
    var onUseForRNode: (DiscoveredInterface) -> Void

    /// Set briefly after "Copy LoRa Params" so the button can show a checkmark.
    var justCopied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: icon + name/type + badges
            HStack(spacing: 8) {
                InterfaceTypeIcon(type: iface.type, host: iface.reachableOn)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: iface.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Text(typeLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    if isConnected {
                        badge(String(localized: "Connected"), color: Theme.success)
                    }
                    badge(statusLabel, color: statusColor)
                }
            }

            // Transport id (truncated)
            if let transportId = iface.transportId {
                HStack(spacing: 4) {
                    Text(String(localized: "Transport:"))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: String(transportId.prefix(12)) + "…")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            // Type-specific details (nil parts omitted by each sub-view)
            if iface.type == "I2PInterface" {
                I2pInterfaceDetails(iface: iface)
            } else if iface.isTcpInterface {
                TcpInterfaceDetails(iface: iface)
            } else if iface.isRadioInterface {
                RadioInterfaceDetails(iface: iface)
            }

            // IFAC row
            if let ifacNetname = iface.ifacNetname, !ifacNetname.isEmpty {
                HStack(spacing: 4) {
                    Text(String(localized: "IFAC:"))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: ifacNetname)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.accentColor)
                    if let ifacNetkey = iface.ifacNetkey, !ifacNetkey.isEmpty {
                        Image(systemName: "key.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accentColor)
                    }
                }
            }

            // Location (tappable → opens Maps)
            if iface.hasLocation {
                LocationDetails(iface: iface, distanceKm: distanceKm)
            }

            // Last heard + hops
            HStack(spacing: 8) {
                Text(String(format: String(localized: "Last heard: %@"), formatLastHeard(iface.lastHeard)))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if let hops = iface.hops {
                    Text(String(format: String(localized: "%lld hops"), Int64(hops)))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            // Expandable all-announced-fields section
            DiscoveredInterfaceAllFieldsSection(iface: iface)

            // Card action buttons (issue #193) — full Android parity:
            // Add to Config / Copy LoRa Params / Use for RNode.
            HStack(spacing: 8) {
                if iface.isTcpInterface && iface.reachableOn != nil {
                    Button {
                        onAddToConfig(iface)
                    } label: {
                        Label(String(localized: "Add to Config"), systemImage: "plus.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("discovery_card_add_config")
                }
                if iface.isRadioInterface && iface.frequency != nil {
                    Button {
                        onCopyLoRaParams(iface)
                    } label: {
                        Label(
                            justCopied ? String(localized: "Copied") : String(localized: "Copy LoRa Params"),
                            systemImage: justCopied ? "checkmark" : "doc.on.doc"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("discovery_card_copy_params")

                    // Rendered only on RNode builds — on other configs the
                    // action is a no-op stub, so this hides the button
                    // instead of leaving a dead tap.
                    #if os(iOS) && COLUMBA_RNODE_ENABLED
                    Button {
                        onUseForRNode(iface)
                    } label: {
                        Label(String(localized: "Use for RNode"), systemImage: "radio")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("discovery_card_use_rnode")
                    #endif
                }
            }
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        .accessibilityIdentifier("discovered_card_" + iface.id)
    }

    // MARK: - Derived

    private var isYggdrasil: Bool {
        iface.isTcpInterface && isYggdrasilAddress(iface.reachableOn)
    }

    private var typeLabel: String {
        isYggdrasil ? String(localized: "Yggdrasil") : formatInterfaceType(iface.type)
    }

    private var statusLabel: String {
        iface.status.isEmpty ? iface.status : iface.status.prefix(1).uppercased() + iface.status.dropFirst()
    }

    private var statusColor: Color {
        switch iface.status {
        case "available": return Theme.success
        case "unknown": return Theme.textSecondary
        default: return .orange
        }
    }

    private func badge(_ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - All Announced Fields

/// DisclosureGroup listing every non-nil field the remote published in
/// its discovery announce (diagnostics: confirm radio parameters, raw
/// timestamps, hashes).
@available(iOS 17.0, macOS 14.0, *)
private struct DiscoveredInterfaceAllFieldsSection: View {

    let iface: DiscoveredInterface

    /// One key/value row (Identifiable by key so ForEach can key it).
    private struct FieldRow: Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    var body: some View {
        DisclosureGroup(String(localized: "All announced fields")) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.key)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 110, alignment: .leading)
                        Text(row.value)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
        .tint(Theme.accentColor)
    }

    // MARK: - Rows (every non-nil field)

    private var rows: [FieldRow] {
        var result: [FieldRow] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            result.append(FieldRow(key: key, value: value))
        }

        add(String(localized: "Transport ID"), iface.transportId)
        add(String(localized: "Network ID"), iface.networkId)
        add(String(localized: "Status code"), iface.statusCode.map(String.init))
        add(String(localized: "Last heard (unix)"), iface.lastHeard > 0 ? String(Int(iface.lastHeard)) : nil)
        add(String(localized: "Heard count"), iface.heardCount.map(String.init))
        add(String(localized: "Stamp value"), iface.stampValue.map(String.init))
        add(String(localized: "Reachable on"), iface.reachableOn)
        add(String(localized: "Port"), iface.port.map(String.init))
        add(String(localized: "Frequency"), iface.frequency.map { String(format: "%.6f Hz", $0) })
        add(String(localized: "Bandwidth"), iface.bandwidth.map { "\($0) Hz" })
        add(String(localized: "Spreading factor"), iface.spreadingFactor.map { "SF\($0)" })
        add(String(localized: "Coding rate"), iface.codingRate.map { "CR 4/\($0)" })
        add(String(localized: "Modulation"), iface.modulation)
        add(String(localized: "Channel"), iface.channel.map(String.init))
        add(String(localized: "Latitude"), iface.latitude.map { String(format: "%.6f", $0) })
        add(String(localized: "Longitude"), iface.longitude.map { String(format: "%.6f", $0) })
        add(String(localized: "Height"), iface.height.map { "\($0) m" })
        add(String(localized: "IFAC passphrase"), iface.ifacNetkey)
        add(String(localized: "Transport"), iface.transport ? "yes" : "no")
        add(String(localized: "Discovery hash"), iface.discoveryHash)
        add(String(localized: "Received at"), iface.receivedAt.map(formatUnixSeconds))
        add(String(localized: "Discovered at"), iface.discoveredAt.map(formatUnixSeconds))
        return result
    }

    private func formatUnixSeconds(_ value: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: value))
    }
}

// MARK: - Type Details

/// TCP details: `host:port`, `host (Yggdrasil)` for 0200::/7 addresses,
/// or a bare port when no host was announced. Nil parts are omitted.
@available(iOS 17.0, macOS 14.0, *)
private struct TcpInterfaceDetails: View {

    let iface: DiscoveredInterface

    var body: some View {
        let text = detailText
        if !text.isEmpty {
            Text(verbatim: text)
                .font(.subheadline.monospaced())
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var detailText: String {
        let host = iface.reachableOn ?? ""
        let port = iface.port
        let yggdrasil = isYggdrasilAddress(iface.reachableOn)
        switch (host.isEmpty, port, yggdrasil) {
        case (false, _, true):
            // Yggdrasil address — the port is implicit (the app connects
            // through the Yggdrasil tunnel, not a raw TCP port).
            return host + " (" + String(localized: "Yggdrasil") + ")"
        case (false, let p?, false):
            return host + ":" + String(p)
        case (false, nil, false):
            return host
        case (true, let p?, _):
            return String(format: String(localized: "Port %lld"), Int64(p))
        default:
            return ""
        }
    }
}

/// I2P details: the b32 address as `<b32>.b32.i2p`.
@available(iOS 17.0, macOS 14.0, *)
private struct I2pInterfaceDetails: View {

    let iface: DiscoveredInterface

    var body: some View {
        if let b32 = iface.reachableOn, !b32.isEmpty {
            Text(verbatim: "\(b32).b32.i2p")
                .font(.subheadline.monospaced())
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// Radio details: "X MHz · Y kHz · SF… · CR 4/…" built from the LoRa
/// parameters — each part omitted when nil.
@available(iOS 17.0, macOS 14.0, *)
private struct RadioInterfaceDetails: View {

    let iface: DiscoveredInterface

    var body: some View {
        let text = parts.joined(separator: " · ")
        if !text.isEmpty {
            Text(verbatim: text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var parts: [String] {
        var result: [String] = []
        if let frequency = iface.frequency {
            result.append(String(format: "%.1f MHz", frequency / 1_000_000.0))
        }
        if let bandwidth = iface.bandwidth {
            result.append("\(bandwidth / 1000) kHz")
        }
        if let sf = iface.spreadingFactor {
            result.append("SF\(sf)")
        }
        if let cr = iface.codingRate {
            result.append("CR 4/\(cr)")
        }
        if let modulation = iface.modulation, !modulation.isEmpty {
            result.append(modulation)
        }
        if let channel = iface.channel {
            result.append("CH\(channel)")
        }
        return result
    }
}

// MARK: - Location Details

/// Tappable "lat, lon (H m) · D km away" row (distance omitted when nil)
/// that opens Apple Maps for the coordinate — same MKPlacemark → MKMapItem
/// pattern as DirectionsLauncher.
@available(iOS 17.0, macOS 14.0, *)
private struct LocationDetails: View {

    let iface: DiscoveredInterface
    let distanceKm: Double?

    var body: some View {
        Button {
            openInMaps()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "location")
                    .font(.caption)
                    .foregroundStyle(Theme.accentColor)

                Text(verbatim: locationText)
                    .font(.caption)
                    .foregroundStyle(Theme.accentColor)
                    .underline()
            }
        }
        .accessibilityHint(String(localized: "Open in Maps"))
    }

    private var locationText: String {
        guard let lat = iface.latitude, let lon = iface.longitude else { return "" }
        var text = String(format: "%.4f, %.4f", lat, lon)
        if let height = iface.height {
            text += " (" + String(format: String(localized: "%lld m"), Int64(Int(height.rounded()))) + ")"
        }
        if let distanceKm {
            let distance = distanceKm < 1.0
                ? String(format: String(localized: "%.0fm away"), distanceKm * 1000.0)
                    : String(format: String(localized: "%.1f km away"), distanceKm)
            text += " · " + distance
        }
        return text
    }

    private func openInMaps() {
        guard let lat = iface.latitude, let lon = iface.longitude else { return }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking,
        ])
    }
}

// MARK: - Interface Type Icon

/// SF Symbol for the interface type (no MDI font on iOS): globe for TCP
/// (leaf for Yggdrasil), mask for I2P, radiowaves for radio, gear for
/// everything else.
@available(iOS 17.0, macOS 14.0, *)
private struct InterfaceTypeIcon: View {

    let type: String
    let host: String?

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 20))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 24)
    }

    private var symbolName: String {
        if type == "TCPServerInterface" || type == "TCPClientInterface" || type == "BackboneInterface" {
            return isYggdrasilAddress(host) ? "leaf" : "globe"
        }
        if type == "I2PInterface" {
            return "person.and.mask"
        }
        if type == "RNodeInterface" || type == "WeaveInterface" || type == "KISSInterface" {
            return "dot.radiowaves.left.and.right"
        }
        return "gearshape"
    }
}

// MARK: - Restarting Overlay

/// Dimmed full-screen overlay while a discovery-settings change triggers
/// the in-process Reticulum restart.
@available(iOS 17.0, macOS 14.0, *)
private struct RestartingOverlay: View {

    var body: some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text(String(localized: "Restarting Reticulum…"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(20)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge))
            }
    }
}

// MARK: - Empty / No-Match Cards

/// Shown when discovery has found nothing at all.
@available(iOS 17.0, macOS 14.0, *)
private struct EmptyDiscoveredCard: View {

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)

            Text(String(localized: "No interfaces discovered yet. Enable discovery above to start finding interfaces announced by other RNS nodes."))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }
}

/// Shown when discovered interfaces exist but none match the active
/// display filters.
@available(iOS 17.0, macOS 14.0, *)
private struct NoFilterMatchesCard: View {

    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)

            Text(String(localized: "No interfaces match your filters."))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button(String(localized: "Clear filters")) {
                onClear()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }
}
