#if COLUMBA_RNODE_ENABLED
//
//  RegionSelectionStep.swift
//  ColumbaApp
//
//  RNode Wizard Step 2: Frequency region selection.
//  Shows 21 ITU regions grouped by continent, community city presets,
//  and a custom radio settings option.
//

import SwiftUI

/// Step 2: Select a frequency region or community preset.
@available(iOS 17.0, macOS 14.0, *)
struct RegionSelectionStep: View {

    @Bindable var wizard: RNodeWizardViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accentColor)
                    .padding(.top, 16)

                Text("Select Your Region")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Text("Choose the frequency band for your location:")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, 12)

            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textSecondary)
                TextField("Search regions or cities...", text: $wizard.regionSearchText)
                    .foregroundStyle(Theme.textPrimary)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                if !wizard.regionSearchText.isEmpty {
                    Button {
                        wizard.regionSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(10)
            .background(Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Region list
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Frequency regions by continent
                    ForEach(wizard.filteredRegions, id: \.0) { continent, regions in
                        regionSection(title: continent, regions: regions)
                    }

                    // Community presets
                    if !wizard.filteredCommunityPresets.isEmpty {
                        sectionHeader("Community Presets")

                        ForEach(wizard.filteredCommunityPresets, id: \.0) { country, presets in
                            VStack(spacing: 6) {
                                ForEach(presets) { preset in
                                    communityPresetCard(preset)
                                }
                            }
                        }
                    }

                    // Custom option
                    if wizard.regionSearchText.isEmpty {
                        sectionHeader("Advanced")
                        customSettingsCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Region Section

    private func regionSection(title: String, regions: [LoRaRegion]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(title)

            ForEach(regions) { region in
                regionCard(region)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.leading, 4)
            .padding(.top, 4)
    }

    // MARK: - Region Card

    private func regionCard(_ region: LoRaRegion) -> some View {
        let isSelected = wizard.selectedRegion == region && wizard.selectedCommunityPreset == nil && !wizard.isCustomMode
        return Button {
            wizard.selectRegion(region)
        } label: {
            HStack(spacing: 12) {
                Text(region.countryFlag)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(region.shortName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    HStack(spacing: 8) {
                        Text("\(region.parameters.freqStart / 1_000_000)–\(region.parameters.freqEnd / 1_000_000) MHz")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)

                        if let dc = region.parameters.dutyCycle {
                            Text("\(Int(dc * 100))% DC")
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                        }
                    }
                }

                Spacer()

                Text("\(region.parameters.maxTxPower) dBm")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accentColor)
                }
            }
            .padding(12)
            .background(isSelected ? Theme.accentColor.opacity(0.1) : Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Theme.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
    }

    // MARK: - Community Preset Card

    private func communityPresetCard(_ preset: CommunityPreset) -> some View {
        let isSelected = wizard.selectedCommunityPreset?.name == preset.name
        return Button {
            wizard.selectCommunityPreset(preset)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accentColor : Theme.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    Text("\(preset.region.shortName) · \(preset.modemPreset.rawValue)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Text(String(format: "%.1f MHz", Double(preset.frequency) / 1_000_000.0))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accentColor)
                }
            }
            .padding(12)
            .background(isSelected ? Theme.accentColor.opacity(0.1) : Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Theme.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
    }

    // MARK: - Custom Settings Card

    private var customSettingsCard: some View {
        Button {
            wizard.selectCustomMode()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundStyle(wizard.isCustomMode ? Theme.accentColor : Theme.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Radio Settings")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    Text("Manually configure all radio parameters")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                if wizard.isCustomMode {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accentColor)
                }
            }
            .padding(12)
            .background(wizard.isCustomMode ? Theme.accentColor.opacity(0.1) : Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(wizard.isCustomMode ? Theme.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
    }
}
#endif
