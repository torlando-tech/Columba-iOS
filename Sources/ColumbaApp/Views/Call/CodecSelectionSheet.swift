//
//  CodecSelectionSheet.swift
//  ColumbaApp
//
//  Sheet for selecting audio quality profile before initiating a call.
//  Groups profiles by Bandwidth/Quality/Latency categories.
//

import SwiftUI
import LXSTSwift

/// Audio quality profile picker presented before starting a call.
@available(iOS 17.0, macOS 14.0, *)
struct CodecSelectionSheet: View {
    @State private var selectedProfile: TelephonyProfile = .qualityMedium
    @Environment(\.dismiss) private var dismiss

    /// Callback when user taps "Call" with the selected profile.
    var onCall: (TelephonyProfile) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(CodecProfileInfo.grouped, id: \.section) { section in
                    Section {
                        ForEach(section.profiles) { info in
                            profileRow(info)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: section.profiles.first?.icon ?? "waveform")
                                .font(.system(size: 12))
                            Text(section.section)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Audio Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                        onCall(selectedProfile)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "phone.fill")
                            Text("Call")
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func profileRow(_ info: CodecProfileInfo) -> some View {
        Button {
            selectedProfile = info.profile
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.displayName)
                        .font(.body)
                        .foregroundStyle(.white)
                    Text("\(info.description) - \(info.bandwidthEstimate)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                if selectedProfile == info.profile {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accentColor)
                        .font(.system(size: 20))
                }
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(
            selectedProfile == info.profile
                ? Theme.accentColor.opacity(0.15)
                : Color.white.opacity(0.05)
        )
    }
}
