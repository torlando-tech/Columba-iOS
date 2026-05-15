#if COLUMBA_RNODE_ENABLED
//
//  FrequencySlotStep.swift
//  ColumbaApp
//
//  RNode Wizard Step 4: Frequency slot selection.
//  Visual spectrum bar, slot picker with +/- buttons, slider,
//  and Meshtastic conflict detection.
//

import SwiftUI

/// Step 4: Select a frequency slot within the chosen region.
@available(iOS 17.0, macOS 14.0, *)
struct FrequencySlotStep: View {

    @Bindable var wizard: RNodeWizardViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accentColor)
                    .padding(.top, 16)

                Text("Frequency Slot")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Text("Select your position in the frequency band:")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 20) {
                    // Spectrum visualization
                    spectrumBar
                        .padding(.horizontal, 16)

                    // Frequency display
                    frequencyDisplay
                        .padding(.horizontal, 16)

                    // Slot picker
                    slotPicker
                        .padding(.horizontal, 16)

                    // Slot slider
                    slotSlider
                        .padding(.horizontal, 16)

                    // Meshtastic conflict warning
                    if wizard.hasMeshtasticConflict {
                        meshtasticWarning
                            .padding(.horizontal, 16)
                    }

                    // Info card
                    infoCard
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Spectrum Bar

    private var spectrumBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Frequency Spectrum")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)

            GeometryReader { geo in
                let totalSlots = max(wizard.totalSlots, 1)
                let slotWidth = geo.size.width / CGFloat(totalSlots)

                ZStack(alignment: .leading) {
                    // Background bar
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.backgroundTertiary)
                        .frame(height: 32)

                    // Meshtastic zone (if applicable)
                    if let region = wizard.selectedRegion,
                       let meshFreq = region.meshtasticDefaultFrequency {
                        let bw = wizard.effectiveBandwidth
                        let params = region.parameters
                        if bw > 0 {
                            let meshSlot = Double(meshFreq - params.freqStart) / Double(bw)
                            let meshX = meshSlot * Double(slotWidth)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.warning.opacity(0.3))
                                .frame(width: max(slotWidth, 4), height: 32)
                                .offset(x: CGFloat(meshX))
                        }
                    }

                    // Selected slot
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accentColor)
                        .frame(width: max(slotWidth, 4), height: 32)
                        .offset(x: CGFloat(wizard.frequencySlot) * slotWidth)
                }
            }
            .frame(height: 32)

            // Band edge labels
            if let region = wizard.selectedRegion {
                HStack {
                    Text(String(format: "%.1f MHz", Double(region.parameters.freqStart) / 1_000_000))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textDisabled)
                    Spacer()
                    Text(String(format: "%.1f MHz", Double(region.parameters.freqEnd) / 1_000_000))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textDisabled)
                }
            }
        }
    }

    // MARK: - Frequency Display

    private var frequencyDisplay: some View {
        VStack(spacing: 4) {
            Text(wizard.frequencyDisplayMHz)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .foregroundStyle(wizard.hasMeshtasticConflict ? Theme.warning : Theme.accentColor)

            if let region = wizard.selectedRegion {
                Text("\(region.shortName) · Slot \(wizard.frequencySlot) of \(wizard.totalSlots)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }

    // MARK: - Slot Picker

    private var slotPicker: some View {
        HStack(spacing: 24) {
            Button {
                if wizard.frequencySlot > 0 {
                    wizard.frequencySlot -= 1
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(wizard.frequencySlot > 0 ? Theme.accentColor : Theme.textDisabled)
            }
            .disabled(wizard.frequencySlot <= 0)

            Text("Slot \(wizard.frequencySlot)")
                .font(.title2.weight(.semibold).monospaced())
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 100)

            Button {
                if wizard.frequencySlot < wizard.totalSlots - 1 {
                    wizard.frequencySlot += 1
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(wizard.frequencySlot < wizard.totalSlots - 1 ? Theme.accentColor : Theme.textDisabled)
            }
            .disabled(wizard.frequencySlot >= wizard.totalSlots - 1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Slot Slider

    private var slotSlider: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { Double(wizard.frequencySlot) },
                    set: { wizard.frequencySlot = Int($0) }
                ),
                in: 0...max(Double(wizard.totalSlots - 1), 1),
                step: 1
            )
            .tint(Theme.accentColor)

            HStack {
                Text("0")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDisabled)
                Spacer()
                Text("\(wizard.totalSlots - 1)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textDisabled)
            }
        }
    }

    // MARK: - Meshtastic Warning

    private var meshtasticWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Theme.warning)

            VStack(alignment: .leading, spacing: 4) {
                Text("Meshtastic Conflict")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.warning)

                Text("This frequency may interfere with Meshtastic devices using their default frequency (\(wizard.meshtasticFrequencyMHz)). Consider choosing a different slot.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .background(Theme.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                .stroke(Theme.warning.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Info Card

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("About Frequency Slots", systemImage: "info.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accentColor)

            Text("Each slot represents a channel within your frequency band. The slot's center frequency is calculated from the band start, modem bandwidth, and slot number. Choose a slot that avoids interference with other devices in your area.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
    }
}
#endif
