//
//  OfflineMapDownloadView.swift
//  ColumbaApp
//
//  4-step download wizard for offline map regions.
//  Steps: Location → Radius/Zoom → Confirm → Download.
//

#if os(iOS)
import SwiftUI
import RNSAPI
import CoreLocation
import MapLibre

@available(iOS 17.0, *)
struct OfflineMapDownloadView: View {
    let mapManager: OfflineMapManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var currentStep = 0
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var searchText = ""
    @State private var searchResults: [String] = []
    @State private var isSearching = false

    // Step 2
    @State private var selectedRadiusKm: Double = 10
    @State private var selectedMinZoom: Int = 0
    @State private var selectedMaxZoom: Int = 14

    // Step 3
    @State private var regionName = ""

    // Step 4
    @State private var isDownloading = false

    // Location
    @State private var locationManager = CLLocationManager()

    private let radiusOptions: [(km: Double, label: String)] = [
        (5, "Small (5 km)"),
        (10, "Medium (10 km)"),
        (25, "Large (25 km)"),
        (50, "XL (50 km)"),
        (100, "Huge (100 km)")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Step indicator
                stepIndicator

                // Content
                switch currentStep {
                case 0: locationStep
                case 1: radiusStep
                case 2: confirmStep
                case 3: downloadingStep
                default: EmptyView()
                }
            }
            .background(Theme.backgroundPrimary)
            .navigationTitle("Download Map")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if currentStep < 3 {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<4) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(step <= currentStep ? Theme.accentColor : Theme.backgroundTertiary)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Step 1: Location

    private var locationStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose Location")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Select the center point for your offline map area.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Search for a place...", text: $searchText)
                        .foregroundStyle(Theme.textPrimary)
                        .onSubmit { geocodeSearch() }
                }
                .padding(12)
                .background(Theme.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // My Location button
                Button {
                    useMyLocation()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 14))
                        Text("Use My Location")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }

                // Manual entry
                VStack(alignment: .leading, spacing: 8) {
                    Text("Or enter coordinates:")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Latitude")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                            TextField("0.0", text: latBinding)
                                .keyboardType(.decimalPad)
                                .padding(10)
                                .background(Theme.backgroundTertiary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Longitude")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                            TextField("0.0", text: lonBinding)
                                .keyboardType(.decimalPad)
                                .padding(10)
                                .background(Theme.backgroundTertiary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                // Selected location display
                if let coord = selectedCoordinate {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(Theme.accentColor)
                        Text(String(format: "%.4f, %.4f", coord.latitude, coord.longitude))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Spacer()

                // Next button
                Button {
                    withAnimation { currentStep = 1 }
                } label: {
                    Text("Continue")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(selectedCoordinate != nil ? Theme.accentColor : Theme.backgroundTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
                .disabled(selectedCoordinate == nil)
            }
            .padding(16)
        }
    }

    // MARK: - Step 2: Radius & Zoom

    private var radiusStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Area Size")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Choose the radius and zoom levels to download.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                // Radius selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("RADIUS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)

                    ForEach(radiusOptions, id: \.km) { option in
                        Button {
                            selectedRadiusKm = option.km
                        } label: {
                            HStack {
                                Image(systemName: selectedRadiusKm == option.km
                                    ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Theme.accentColor)
                                Text(option.label)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                Divider().overlay(Theme.divider)

                // Zoom range
                VStack(alignment: .leading, spacing: 8) {
                    Text("ZOOM RANGE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)

                    HStack {
                        Text("Min: \(selectedMinZoom)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 60, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(selectedMinZoom) },
                            set: { selectedMinZoom = Int($0); selectedMaxZoom = max(selectedMaxZoom, selectedMinZoom) }
                        ), in: 0...14, step: 1)
                        .tint(Theme.accentColor)
                    }

                    HStack {
                        Text("Max: \(selectedMaxZoom)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 60, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(selectedMaxZoom) },
                            set: { selectedMaxZoom = Int($0); selectedMinZoom = min(selectedMinZoom, selectedMaxZoom) }
                        ), in: 0...14, step: 1)
                        .tint(Theme.accentColor)
                    }

                    HStack {
                        zoomLabel(0, "World")
                        Spacer()
                        zoomLabel(7, "City")
                        Spacer()
                        zoomLabel(14, "Street")
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                }

                // Estimate
                let estimate = mapManager.estimateTileCount(
                    center: selectedCoordinate ?? CLLocationCoordinate2D(),
                    radiusKm: selectedRadiusKm,
                    minZoom: selectedMinZoom,
                    maxZoom: selectedMaxZoom
                )

                HStack {
                    VStack(spacing: 2) {
                        Text("\(estimate.tiles)")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Tiles")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 2) {
                        Text(estimate.sizeEstimate)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Est. Size")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(12)
                .background(Theme.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Spacer()

                // Navigation buttons
                HStack(spacing: 12) {
                    Button {
                        withAnimation { currentStep = 0 }
                    } label: {
                        Text("Back")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.backgroundTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                    }

                    Button {
                        withAnimation { currentStep = 2 }
                    } label: {
                        Text("Continue")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Step 3: Confirm

    private var confirmStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Confirm Download")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                // Region name
                VStack(alignment: .leading, spacing: 4) {
                    Text("Region Name")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("My Offline Area", text: $regionName)
                        .padding(12)
                        .background(Theme.backgroundTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Summary
                VStack(alignment: .leading, spacing: 8) {
                    summaryRow("Location", value: selectedCoordinate.map {
                        String(format: "%.4f, %.4f", $0.latitude, $0.longitude)
                    } ?? "—")
                    summaryRow("Radius", value: "\(Int(selectedRadiusKm)) km")
                    summaryRow("Zoom Range", value: "\(selectedMinZoom) – \(selectedMaxZoom)")

                    let estimate = mapManager.estimateTileCount(
                        center: selectedCoordinate ?? CLLocationCoordinate2D(),
                        radiusKm: selectedRadiusKm,
                        minZoom: selectedMinZoom,
                        maxZoom: selectedMaxZoom
                    )
                    summaryRow("Est. Tiles", value: "\(estimate.tiles)")
                    summaryRow("Est. Size", value: estimate.sizeEstimate)
                }
                .padding(12)
                .background(Theme.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Warning
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    Text("Downloading requires an internet connection. The map tiles will be stored locally for offline use.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                // Navigation buttons
                HStack(spacing: 12) {
                    Button {
                        withAnimation { currentStep = 1 }
                    } label: {
                        Text("Back")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.backgroundTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                    }

                    Button {
                        startDownload()
                    } label: {
                        Text("Download")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Step 4: Downloading

    private var downloadingStep: some View {
        VStack(spacing: 24) {
            Spacer()

            // Progress circle
            ZStack {
                Circle()
                    .stroke(Theme.backgroundTertiary, lineWidth: 8)
                    .frame(width: 120, height: 120)

                if let region = regions.last(where: { $0.status == .downloading }) {
                    Circle()
                        .trim(from: 0, to: CGFloat(region.downloadProgress))
                        .stroke(Theme.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 120, height: 120)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: region.downloadProgress)

                    Text("\(Int(region.downloadProgress * 100))%")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }

            if let region = regions.last {
                Text("Downloading \(region.name)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)

                Text("\(region.tileCount) tiles downloaded")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if region.status == .complete {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text("Download complete!")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.success)
                    }
                    .padding(.top, 8)

                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                    }
                    .padding(.horizontal, 16)
                }

                if region.status == .error {
                    Text("Download failed. Please try again.")
                        .font(.caption)
                        .foregroundStyle(Theme.error)

                    Button {
                        dismiss()
                    } label: {
                        Text("Close")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.backgroundTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                    }
                    .padding(.horizontal, 16)
                }
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private var regions: [OfflineMapRegion] { mapManager.regions }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func zoomLabel(_ level: Int, _ text: String) -> some View {
        VStack(spacing: 2) {
            Text("\(level)")
                .font(.caption2.weight(.medium))
            Text(text)
                .font(.caption2)
        }
    }

    // MARK: - Coordinate Bindings

    private var latBinding: Binding<String> {
        Binding(
            get: { selectedCoordinate.map { String(format: "%.6f", $0.latitude) } ?? "" },
            set: { newValue in
                if let lat = Double(newValue) {
                    let lon = selectedCoordinate?.longitude ?? 0
                    selectedCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
            }
        )
    }

    private var lonBinding: Binding<String> {
        Binding(
            get: { selectedCoordinate.map { String(format: "%.6f", $0.longitude) } ?? "" },
            set: { newValue in
                if let lon = Double(newValue) {
                    let lat = selectedCoordinate?.latitude ?? 0
                    selectedCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
            }
        )
    }

    // MARK: - Actions

    private func useMyLocation() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        if let location = locationManager.location {
            selectedCoordinate = location.coordinate
        }
    }

    private func geocodeSearch() {
        guard !searchText.isEmpty else { return }
        let geocoder = CLGeocoder()
        isSearching = true
        geocoder.geocodeAddressString(searchText) { placemarks, error in
            isSearching = false
            if let location = placemarks?.first?.location {
                selectedCoordinate = location.coordinate
            }
        }
    }

    private func startDownload() {
        guard let center = selectedCoordinate else { return }
        let name = regionName.isEmpty ? "Offline Region" : regionName

        mapManager.downloadRegion(
            name: name,
            center: center,
            radiusKm: selectedRadiusKm,
            minZoom: selectedMinZoom,
            maxZoom: selectedMaxZoom
        )

        withAnimation { currentStep = 3 }
    }
}
#endif
