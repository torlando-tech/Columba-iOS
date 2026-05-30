#if COLUMBA_RNODE_ENABLED
//
//  ModemPresetStep.swift
//  ColumbaApp
//
//  RNode Wizard Step 3: Modem preset selection.
//  Shows 8 modem presets (Short Turbo → Long Slow) with specs and descriptions.
//

import SwiftUI
import RNSAPI

/// Step 3: Select a modem preset for speed/range tradeoff.
@available(iOS 17.0, macOS 14.0, *)
struct ModemPresetStep: View {

    @Bindable var wizard: RNodeWizardViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accentColor)
                    .padding(.top, 16)

                Text("Modem Preset")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Text("Choose speed vs. range tradeoff:")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, 16)

            // Preset list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ModemPreset.allCases) { preset in
                        presetCard(preset)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Preset Card

    private func presetCard(_ preset: ModemPreset) -> some View {
        let isSelected = wizard.selectedModemPreset == preset
        return Button {
            wizard.selectedModemPreset = preset
        } label: {
            HStack(spacing: 12) {
                // Speed indicator bars
                speedIndicator(for: preset)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(preset.rawValue)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)

                        if preset.isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(preset.subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    Text(preset.specsString)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textDisabled)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accentColor)
                }
            }
            .padding(14)
            .background(isSelected ? Theme.accentColor.opacity(0.1) : Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                    .stroke(isSelected ? Theme.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
    }

    // MARK: - Speed Indicator

    /// Visual speed indicator (more bars = faster).
    private func speedIndicator(for preset: ModemPreset) -> some View {
        let level: Int = {
            switch preset {
            case .shortTurbo: return 4
            case .shortFast: return 4
            case .shortSlow: return 3
            case .mediumFast: return 3
            case .mediumSlow: return 2
            case .longFast: return 2
            case .longModerate: return 1
            case .longSlow: return 1
            }
        }()

        return HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar < level ? Theme.accentColor : Theme.textDisabled.opacity(0.3))
                    .frame(width: 4, height: CGFloat(8 + bar * 4))
            }
        }
        .frame(width: 28, height: 24, alignment: .bottom)
    }
}
#endif
