//
//  RNodeWizardViewModel.swift
//  ColumbaApp
//
//  State management for the 5-step RNode configuration wizard.
//  Handles step navigation, frequency calculation, and Meshtastic conflict detection.
//

import Foundation
import RNSAPI
import SwiftUI

// MARK: - Wizard Step

/// Steps in the RNode configuration wizard.
@available(iOS 17.0, macOS 14.0, *)
enum RNodeWizardStep: Int, CaseIterable, Identifiable {
    case device = 0
    case region = 1
    case modem = 2
    case frequency = 3
    case review = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .device: return "Device"
        case .region: return "Region"
        case .modem: return "Modem"
        case .frequency: return "Frequency"
        case .review: return "Review"
        }
    }
}

// MARK: - ViewModel

/// ViewModel for the RNode configuration wizard.
///
/// Manages wizard step navigation, region/modem/frequency selection,
/// and generates final configuration for the InterfaceManagementViewModel.
@available(iOS 17.0, macOS 14.0, *)
@Observable
@MainActor
final class RNodeWizardViewModel {

    // MARK: - Navigation

    /// Index into activeSteps for current position.
    var currentStepIndex: Int = 0

    /// Whether the wizard is in edit mode (pre-populated from existing config).
    var isEditing: Bool = false

    // MARK: - Step 1: Device

    var selectedDeviceName: String = ""
    var devicePaired: Bool = false

    // MARK: - Step 2: Region

    var selectedRegion: LoRaRegion?
    var selectedCommunityPreset: CommunityPreset?
    var isCustomMode: Bool = false
    var regionSearchText: String = ""

    // MARK: - Step 3: Modem

    var selectedModemPreset: ModemPreset = .longFast

    // MARK: - Step 4: Frequency

    var frequencySlot: Int = 0

    // MARK: - Step 5: Review

    var interfaceName: String = "RNode"
    var showAdvanced: Bool = false
    var customFrequency: String = ""
    var customBandwidth: String = ""
    var customTxPower: String = ""
    var customSpreadingFactor: String = ""
    var customCodingRate: String = ""

    // MARK: - Active Steps

    /// Steps shown based on selection (community preset/custom skips modem + frequency).
    var activeSteps: [RNodeWizardStep] {
        if selectedCommunityPreset != nil || isCustomMode {
            return [.device, .region, .review]
        }
        return RNodeWizardStep.allCases
    }

    /// Current step enum value.
    var currentStep: RNodeWizardStep {
        let steps = activeSteps
        guard currentStepIndex >= 0, currentStepIndex < steps.count else {
            return steps.first ?? .device
        }
        return steps[currentStepIndex]
    }

    /// Total number of active steps.
    var totalSteps: Int { activeSteps.count }

    /// Whether on the last step.
    var isLastStep: Bool { currentStepIndex >= activeSteps.count - 1 }

    /// Whether on the first step.
    var isFirstStep: Bool { currentStepIndex == 0 }

    // MARK: - Navigation

    /// Whether the Next button should be enabled for the current step.
    var canProceed: Bool {
        switch currentStep {
        case .device:
            return !selectedDeviceName.isEmpty && devicePaired
        case .region:
            return selectedRegion != nil || selectedCommunityPreset != nil || isCustomMode
        case .modem:
            return true // always has a selection (default longFast)
        case .frequency:
            return true // slot defaults to 0
        case .review:
            return !interfaceName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func nextStep() {
        guard !isLastStep else { return }
        currentStepIndex += 1
    }

    func previousStep() {
        guard !isFirstStep else { return }
        currentStepIndex -= 1
    }

    // MARK: - Frequency Calculation

    /// The calculated frequency based on region + modem + slot selections.
    var calculatedFrequency: UInt32 {
        if let preset = selectedCommunityPreset {
            return preset.frequency
        }
        if isCustomMode, let freq = UInt32(customFrequency) {
            return freq
        }
        guard let region = selectedRegion else { return 915_000_000 }
        let bandwidth = selectedModemPreset.parameters.bandwidth
        return region.parameters.slotFrequency(slot: frequencySlot, bandwidth: bandwidth)
    }

    /// The effective bandwidth based on selections.
    var effectiveBandwidth: UInt32 {
        if isCustomMode, let bw = UInt32(customBandwidth) {
            return bw
        }
        if let preset = selectedCommunityPreset {
            return preset.modemPreset.parameters.bandwidth
        }
        return selectedModemPreset.parameters.bandwidth
    }

    /// The effective TX power (always editable, defaults to 17 dBm).
    /// Capped to 17 dBm by default because most RNode hardware (SX1276)
    /// maxes at 17 dBm. SX1262 can do 22 dBm. Users can override in advanced.
    var effectiveTxPower: UInt8 {
        if let tx = UInt8(customTxPower), tx > 0 {
            return tx
        }
        return min(selectedRegion?.parameters.maxTxPower ?? 17, 17)
    }

    /// The effective spreading factor.
    var effectiveSpreadingFactor: UInt8 {
        if isCustomMode, let sf = UInt8(customSpreadingFactor) {
            return sf
        }
        if let preset = selectedCommunityPreset {
            return preset.modemPreset.parameters.spreadingFactor
        }
        return selectedModemPreset.parameters.spreadingFactor
    }

    /// The effective coding rate.
    var effectiveCodingRate: UInt8 {
        if isCustomMode, let cr = UInt8(customCodingRate) {
            return cr
        }
        if let preset = selectedCommunityPreset {
            return preset.modemPreset.parameters.codingRate
        }
        return selectedModemPreset.parameters.codingRate
    }

    /// The effective modem preset (from community preset or selection).
    var effectiveModemPreset: ModemPreset {
        selectedCommunityPreset?.modemPreset ?? selectedModemPreset
    }

    /// Total available frequency slots for the selected region and modem.
    var totalSlots: Int {
        guard let region = selectedRegion else { return 0 }
        return region.parameters.totalSlots(bandwidth: selectedModemPreset.parameters.bandwidth)
    }

    /// Frequency display string in MHz.
    var frequencyDisplayMHz: String {
        let freq = calculatedFrequency
        let mhz = Double(freq) / 1_000_000.0
        return String(format: "%.3f MHz", mhz)
    }

    // MARK: - Meshtastic Conflict Detection

    /// Whether the selected frequency conflicts with Meshtastic defaults.
    var hasMeshtasticConflict: Bool {
        guard let region = selectedRegion,
              let meshFreq = region.meshtasticDefaultFrequency else { return false }
        let bw = effectiveBandwidth
        let freq = calculatedFrequency
        let halfBw = bw / 2
        // Check if frequency bands overlap
        let ourLow = freq - halfBw
        let ourHigh = freq + halfBw
        let meshLow = meshFreq - halfBw
        let meshHigh = meshFreq + halfBw
        return ourLow < meshHigh && ourHigh > meshLow
    }

    /// Meshtastic frequency display for conflict warnings.
    var meshtasticFrequencyMHz: String {
        guard let region = selectedRegion,
              let freq = region.meshtasticDefaultFrequency else { return "" }
        return String(format: "%.3f MHz", Double(freq) / 1_000_000.0)
    }

    // MARK: - Region Filtering

    /// Filtered regions based on search text.
    var filteredRegions: [(String, [LoRaRegion])] {
        if regionSearchText.isEmpty {
            return LoRaRegion.byContinent
        }
        let query = regionSearchText.lowercased()
        let filtered = LoRaRegion.allCases.filter {
            $0.rawValue.lowercased().contains(query) ||
            $0.shortName.lowercased().contains(query) ||
            $0.continent.lowercased().contains(query)
        }
        if filtered.isEmpty { return [] }
        let grouped = Dictionary(grouping: filtered, by: \.continent)
        let order = ["Americas", "Europe", "Asia-Pacific", "Global"]
        return order.compactMap { continent in
            guard let regions = grouped[continent] else { return nil }
            return (continent, regions)
        }
    }

    /// Filtered community presets based on search text.
    var filteredCommunityPresets: [(String, [CommunityPreset])] {
        if regionSearchText.isEmpty {
            return CommunityPreset.byCountry
        }
        let query = regionSearchText.lowercased()
        let filtered = CommunityPreset.presets.filter {
            $0.name.lowercased().contains(query) ||
            $0.country.lowercased().contains(query) ||
            $0.region.shortName.lowercased().contains(query)
        }
        if filtered.isEmpty { return [] }
        let grouped = Dictionary(grouping: filtered, by: \.country)
        return grouped.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: - Select Community Preset

    func selectCommunityPreset(_ preset: CommunityPreset) {
        selectedCommunityPreset = preset
        selectedRegion = preset.region
        selectedModemPreset = preset.modemPreset
        frequencySlot = preset.frequencySlot
        isCustomMode = false
    }

    /// Select a region and clear any community preset.
    func selectRegion(_ region: LoRaRegion) {
        selectedRegion = region
        selectedCommunityPreset = nil
        isCustomMode = false
        // Apply region-specific default slot (matches Android Columba behaviour).
        // Uses current modem bandwidth so the slot is valid for the selected preset.
        frequencySlot = region.defaultFrequencySlot(bandwidth: selectedModemPreset.parameters.bandwidth)
    }

    /// Select custom mode (manual radio parameters).
    func selectCustomMode() {
        isCustomMode = true
        selectedRegion = nil
        selectedCommunityPreset = nil
    }

    // MARK: - Populate from Existing Config

    /// Pre-populate wizard state from an existing interface config (for editing).
    func populateFromConfig(
        name: String,
        deviceName: String,
        frequency: UInt32,
        bandwidth: UInt32,
        txPower: UInt8,
        spreadingFactor: UInt8,
        codingRate: UInt8
    ) {
        isEditing = true
        interfaceName = name
        selectedDeviceName = deviceName
        devicePaired = true // already paired when editing existing config
        customFrequency = String(frequency)
        customBandwidth = String(bandwidth)
        customTxPower = String(txPower)
        customSpreadingFactor = String(spreadingFactor)
        customCodingRate = String(codingRate)

        // Try to match a region
        for region in LoRaRegion.allCases {
            let params = region.parameters
            if frequency >= params.freqStart && frequency <= params.freqEnd {
                selectedRegion = region
                // Try to match modem preset
                for preset in ModemPreset.allCases {
                    let mp = preset.parameters
                    if mp.bandwidth == bandwidth && mp.spreadingFactor == spreadingFactor && mp.codingRate == codingRate {
                        selectedModemPreset = preset
                        // Calculate slot
                        if bandwidth > 0 {
                            let slotCalc = Int((frequency - params.freqStart - bandwidth / 2) / bandwidth)
                            frequencySlot = max(0, slotCalc)
                        }
                        return
                    }
                }
                // No modem match — use custom mode
                isCustomMode = true
                return
            }
        }
        // No region match — use custom mode
        isCustomMode = true
    }
}
