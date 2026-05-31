//
//  OfflineMapsScreen.swift
//  ColumbaApp
//
//  Management screen for downloaded offline map regions.
//  Shows region list with status, size, and delete controls.
//

#if os(iOS)
import SwiftUI
import RNSAPI

@available(iOS 17.0, *)
struct OfflineMapsScreen: View {
    let mapManager: OfflineMapManager

    @State private var showDownloadWizard = false
    @State private var regionToDelete: OfflineMapRegion?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                storageSummaryCard
                regionsList
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.backgroundPrimary)
        .navigationTitle("Offline Maps")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDownloadWizard = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.accentColor)
                }
            }
        }
        .sheet(isPresented: $showDownloadWizard) {
            OfflineMapDownloadView(mapManager: mapManager)
        }
        .alert("Delete Region?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { regionToDelete = nil }
            Button("Delete", role: .destructive) {
                if let region = regionToDelete {
                    mapManager.deleteRegion(id: region.id)
                    regionToDelete = nil
                }
            }
        } message: {
            if let region = regionToDelete {
                Text("This will remove \"\(region.name)\" and free up \(region.formattedSize) of storage.")
            }
        }
    }

    // MARK: - Storage Summary

    private var storageSummaryCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.accentColor.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: "internaldrive")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Offline Storage")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    HStack(spacing: 12) {
                        Text("\(mapManager.regions.count) region\(mapManager.regions.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)

                        let formatter = ByteCountFormatter()
                        Text(formatter.string(fromByteCount: mapManager.totalSize))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Spacer()
            }
            .padding(16)
        }
        .glassCard()
    }

    // MARK: - Regions List

    private var regionsList: some View {
        VStack(spacing: 12) {
            if mapManager.regions.isEmpty {
                emptyStateCard
            } else {
                ForEach(mapManager.regions) { region in
                    regionCard(region)
                }
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))

            Text("No Offline Maps")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textSecondary)

            Text("Download map regions for offline use when you don't have internet access.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                showDownloadWizard = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14, weight: .medium))
                    Text("Download Region")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Theme.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    private func regionCard(_ region: OfflineMapRegion) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Status icon
                ZStack {
                    Circle()
                        .fill(statusColor(region).opacity(0.2))
                        .frame(width: 36, height: 36)
                    Image(systemName: statusIcon(region))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(statusColor(region))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(region.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)

                        if region.isDefault {
                            Text("Default")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accentColor)
                                .clipShape(Capsule())
                        }
                    }

                    Text(String(format: "%.2f, %.2f", region.centerLatitude, region.centerLongitude))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    HStack(spacing: 8) {
                        Text(region.formattedSize)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)

                        Text("Zoom \(region.minZoom)-\(region.maxZoom)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)

                        Text("\(Int(region.radiusKm)) km")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Spacer()

                // Actions
                Menu {
                    if !region.isDefault {
                        Button {
                            mapManager.setDefaultRegion(id: region.id)
                        } label: {
                            Label("Set as Default", systemImage: "star")
                        }
                    }

                    Button(role: .destructive) {
                        regionToDelete = region
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(12)

            // Progress bar for downloading
            if region.status == .downloading {
                ProgressView(value: region.downloadProgress)
                    .tint(Theme.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .glassCard()
    }

    // MARK: - Helpers

    private func statusColor(_ region: OfflineMapRegion) -> Color {
        switch region.status {
        case .complete: return Theme.success
        case .downloading: return Theme.accentColor
        case .pending: return Theme.warning
        case .error: return Theme.error
        }
    }

    private func statusIcon(_ region: OfflineMapRegion) -> String {
        switch region.status {
        case .complete: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .pending: return "clock"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
#endif
