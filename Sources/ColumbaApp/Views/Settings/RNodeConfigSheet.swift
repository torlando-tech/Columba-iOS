#if COLUMBA_RNODE_ENABLED
//
//  RNodeConfigSheet.swift
//  ColumbaApp
//
//  Configuration sheet for RNode LoRa radio interface.
//  Provides BLE device selection, regional/modem presets, and manual radio parameter entry.
//

import SwiftUI
import RNSAPI

/// Configuration sheet for RNode LoRa interfaces.
///
/// Features:
/// - BLE device selection via picker sheet
/// - Regional presets (frequency + TX power)
/// - Modem presets (bandwidth + SF + CR)
/// - Manual radio parameter entry with validation
/// - Frequency validation (137 MHz - 3 GHz)
@available(iOS 17.0, macOS 14.0, *)
struct RNodeConfigSheet: View {

    // MARK: - Properties

    @Bindable var viewModel: InterfaceManagementViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showDevicePicker = false
    @State private var selectedRegionalPreset: RegionalPreset?
    @State private var selectedModemPreset: ModemPreset?

    // MARK: - Body

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
                            placeholder: "e.g., My RNode",
                            text: $viewModel.configName,
                            error: viewModel.nameError
                        )

                        // Device Selection
                        deviceSelectionSection

                        // Regional Preset
                        regionalPresetSection

                        // Modem Preset
                        modemPresetSection

                        // Radio Parameters
                        radioParametersSection

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

                        // Info Card
                        infoCard
                    }
                    .padding(16)
                }
            }
            .navigationTitle(viewModel.isEditing ? "Edit RNode" : "Add RNode")
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
        .sheet(isPresented: $showDevicePicker) {
            BLEDevicePickerSheet(viewModel: viewModel)
                .presentationDetents([.medium])
        }
    }

    // MARK: - Device Selection

    private var deviceSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BLE Device")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            HStack {
                if viewModel.configDeviceName.isEmpty {
                    Text("No device selected")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(viewModel.configDeviceName)
                        .foregroundStyle(Theme.textPrimary)
                }

                Spacer()

                Button("Select") {
                    showDevicePicker = true
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let error = viewModel.deviceNameError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.error)
            }
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    // MARK: - Regional Preset

    private var regionalPresetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Regional Preset (optional)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            Picker("Regional Preset", selection: $selectedRegionalPreset) {
                Text("Manual").tag(nil as RegionalPreset?)
                ForEach(RegionalPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset as RegionalPreset?)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accentColor)
            .onChange(of: selectedRegionalPreset) { _, preset in
                if let preset {
                    viewModel.configFrequency = String(preset.parameters.frequency)
                    // Cap at 17 dBm — most RNode hardware (SX1276) maxes at 17 dBm.
                    // maxTxPower is the regulatory ceiling (e.g., 30 dBm for US),
                    // not a sensible default. Users can override in the field.
                    viewModel.configTxPower = String(min(preset.parameters.maxTxPower, UInt8(17)))
                }
            }
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    // MARK: - Modem Preset

    private var modemPresetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Modem Preset (optional)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            Picker("Modem Preset", selection: $selectedModemPreset) {
                Text("Manual").tag(nil as ModemPreset?)
                ForEach(ModemPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset as ModemPreset?)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accentColor)
            .onChange(of: selectedModemPreset) { _, preset in
                if let preset {
                    viewModel.configBandwidth = String(preset.parameters.bandwidth)
                    viewModel.configSpreadingFactor = String(preset.parameters.spreadingFactor)
                    viewModel.configCodingRate = String(preset.parameters.codingRate)
                }
            }
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    // MARK: - Radio Parameters

    private var radioParametersSection: some View {
        VStack(spacing: 16) {
            configField(
                title: "Frequency (Hz)",
                placeholder: "915000000",
                text: $viewModel.configFrequency,
                error: viewModel.frequencyError,
                isNumeric: true
            )

            configField(
                title: "Bandwidth (Hz)",
                placeholder: "125000",
                text: $viewModel.configBandwidth,
                isNumeric: true
            )

            configField(
                title: "TX Power (dBm)",
                placeholder: "17",
                text: $viewModel.configTxPower,
                isNumeric: true
            )

            configField(
                title: "Spreading Factor",
                placeholder: "7",
                text: $viewModel.configSpreadingFactor,
                isNumeric: true
            )

            configField(
                title: "Coding Rate",
                placeholder: "5",
                text: $viewModel.configCodingRate,
                isNumeric: true
            )
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    // MARK: - Info Card

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("About RNode", systemImage: "info.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accentColor)

            Text("RNode is a LoRa radio interface that enables off-grid mesh communication. Select a regional preset for your area, or configure radio parameters manually.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .background(Theme.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    // MARK: - Config Field Helper

    private func configField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        error: String? = nil,
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

            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.error)
            }
        }
    }
}
#endif
