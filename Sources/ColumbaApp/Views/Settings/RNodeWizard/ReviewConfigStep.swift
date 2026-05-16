#if COLUMBA_RNODE_ENABLED
//
//  ReviewConfigStep.swift
//  ColumbaApp
//
//  RNode Wizard Step 5: Configuration review and save.
//  Shows summary of all selections with expandable advanced settings.
//

import SwiftUI
import RNSAPI

/// Step 5: Review configuration and save the RNode interface.
@available(iOS 17.0, macOS 14.0, *)
struct ReviewConfigStep: View {

    @Bindable var wizard: RNodeWizardViewModel
    let onSave: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.accentColor)
                        .padding(.top, 16)

                    Text("Review Configuration")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Verify your settings before configuring:")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, 8)

                // Interface name
                VStack(alignment: .leading, spacing: 8) {
                    Text("Interface Name")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    TextField("RNode", text: $wizard.interfaceName)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Theme.backgroundTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
                        .foregroundStyle(Theme.textPrimary)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        #endif
                }
                .padding(16)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                .padding(.horizontal, 16)

                // Connection summary
                summaryCard(title: "Connection", icon: "antenna.radiowaves.left.and.right") {
                    summaryRow(label: "Device", value: wizard.selectedDeviceName.isEmpty ? "Not selected" : wizard.selectedDeviceName)
                    summaryRow(label: "Type", value: "Bluetooth LE")
                }

                // Radio configuration summary
                summaryCard(title: "Radio Configuration", icon: "radio") {
                    if let preset = wizard.selectedCommunityPreset {
                        summaryRow(label: "Preset", value: preset.name)
                        summaryRow(label: "Region", value: preset.region.shortName)
                        summaryRow(label: "Modem", value: preset.modemPreset.rawValue)
                    } else if wizard.isCustomMode {
                        summaryRow(label: "Mode", value: "Custom")
                    } else if let region = wizard.selectedRegion {
                        summaryRow(label: "Region", value: region.rawValue)
                        summaryRow(label: "Modem", value: wizard.selectedModemPreset.rawValue)
                        summaryRow(label: "Slot", value: "\(wizard.frequencySlot)")
                    }
                    summaryRow(label: "Frequency", value: wizard.frequencyDisplayMHz, highlighted: true)
                    summaryRow(label: "TX Power", value: "\(wizard.effectiveTxPower) dBm")
                }

                // Advanced settings
                advancedSection
                    .padding(.horizontal, 16)

                // Meshtastic warning
                if wizard.hasMeshtasticConflict {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                        Text("Selected frequency may conflict with Meshtastic devices.")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                    .padding(12)
                    .background(Theme.warning.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                }

                // Save button
                Button(action: onSave) {
                    Text(wizard.isEditing ? "Update Configuration" : "Configure RNode")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(wizard.canProceed ? Theme.accentGradient : LinearGradient(colors: [Theme.textDisabled], startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!wizard.canProceed)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Summary Card

    private func summaryCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentColor)

            Divider().overlay(Theme.divider)

            content()
        }
        .padding(16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        .padding(.horizontal, 16)
    }

    private func summaryRow(label: String, value: String, highlighted: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(highlighted ? .semibold : .regular))
                .foregroundStyle(highlighted ? Theme.accentColor : Theme.textPrimary)
        }
    }

    // MARK: - Advanced Settings

    private var advancedSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    wizard.showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Text("Advanced Settings")
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
                VStack(spacing: 12) {
                    if wizard.isCustomMode {
                        customField(title: "Frequency (Hz)", text: $wizard.customFrequency, placeholder: "915000000")
                        customField(title: "Bandwidth (Hz)", text: $wizard.customBandwidth, placeholder: "125000")
                        customField(title: "TX Power (dBm)", text: $wizard.customTxPower, placeholder: "17")
                        customField(title: "Spreading Factor", text: $wizard.customSpreadingFactor, placeholder: "7")
                        customField(title: "Coding Rate", text: $wizard.customCodingRate, placeholder: "5")
                    } else {
                        readOnlyRow(label: "Frequency", value: "\(wizard.calculatedFrequency) Hz")
                        readOnlyRow(label: "Bandwidth", value: "\(wizard.effectiveBandwidth) Hz")
                        customField(title: "TX Power (dBm)", text: $wizard.customTxPower, placeholder: "\(wizard.effectiveTxPower)")
                        readOnlyRow(label: "Spreading Factor", value: "\(wizard.effectiveSpreadingFactor)")
                        readOnlyRow(label: "Coding Rate", value: "4/\(wizard.effectiveCodingRate)")
                    }
                }
                .padding(16)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func customField(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Theme.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(Theme.textPrimary)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
        }
    }

    private func readOnlyRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textPrimary)
        }
    }
}
#endif
