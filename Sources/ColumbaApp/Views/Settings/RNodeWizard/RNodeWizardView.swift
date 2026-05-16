#if COLUMBA_RNODE_ENABLED
//
//  RNodeWizardView.swift
//  ColumbaApp
//
//  5-step wizard container for RNode LoRa radio configuration.
//  Matches the Android Columba RNode setup wizard layout.
//

import SwiftUI
import RNSAPI

/// 5-step RNode configuration wizard.
///
/// Steps: Device Discovery → Region → Modem Preset → Frequency Slot → Review.
/// Community presets and custom mode skip modem + frequency steps.
@available(iOS 17.0, macOS 14.0, *)
struct RNodeWizardView: View {

    // MARK: - Properties

    @Bindable var viewModel: InterfaceManagementViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var wizard = RNodeWizardViewModel()

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Step content
                    Group {
                        switch wizard.currentStep {
                        case .device:
                            DeviceDiscoveryStep(wizard: wizard)
                        case .region:
                            RegionSelectionStep(wizard: wizard)
                        case .modem:
                            ModemPresetStep(wizard: wizard)
                        case .frequency:
                            FrequencySlotStep(wizard: wizard)
                        case .review:
                            ReviewConfigStep(
                                wizard: wizard,
                                onSave: { completeWizard() }
                            )
                        }
                    }

                    // Navigation bar (not on review — it has its own save button)
                    if wizard.currentStep != .review {
                        navigationBar
                    }

                    // Step indicator dots
                    stepIndicator
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle(wizard.isEditing ? "Edit RNode" : "Configure RNode")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
        .onAppear {
            // Pre-populate for edit mode
            if viewModel.isEditing {
                wizard.populateFromConfig(
                    name: viewModel.configName,
                    deviceName: viewModel.configDeviceName,
                    frequency: UInt32(viewModel.configFrequency) ?? 915_000_000,
                    bandwidth: UInt32(viewModel.configBandwidth) ?? 125_000,
                    txPower: UInt8(viewModel.configTxPower) ?? 17,
                    spreadingFactor: UInt8(viewModel.configSpreadingFactor) ?? 7,
                    codingRate: UInt8(viewModel.configCodingRate) ?? 5
                )
                // Jump to review step for editing
                wizard.currentStepIndex = wizard.activeSteps.count - 1
            }
        }
        .animation(.easeInOut(duration: 0.25), value: wizard.currentStepIndex)
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack(spacing: 16) {
            if !wizard.isFirstStep {
                Button {
                    wizard.previousStep()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.backgroundSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }

            Button {
                wizard.nextStep()
            } label: {
                HStack(spacing: 6) {
                    Text(wizard.isLastStep ? "Review" : "Continue")
                    Image(systemName: "chevron.right")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(wizard.canProceed ? Theme.accentGradient : LinearGradient(colors: [Theme.textDisabled], startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!wizard.canProceed)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Array(wizard.activeSteps.enumerated()), id: \.element.id) { index, _ in
                Circle()
                    .fill(index == wizard.currentStepIndex ? Theme.accentColor : Theme.textDisabled)
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Complete Wizard

    private func completeWizard() {
        // Transfer wizard state to InterfaceManagementViewModel
        viewModel.configDeviceName = wizard.selectedDeviceName
        viewModel.configFrequency = String(wizard.calculatedFrequency)
        viewModel.configBandwidth = String(wizard.effectiveBandwidth)
        viewModel.configTxPower = String(wizard.effectiveTxPower)
        viewModel.configSpreadingFactor = String(wizard.effectiveSpreadingFactor)
        viewModel.configCodingRate = String(wizard.effectiveCodingRate)
        viewModel.configName = wizard.interfaceName

        viewModel.saveInterface()
    }
}
#endif
