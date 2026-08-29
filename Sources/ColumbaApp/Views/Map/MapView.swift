//
//  MapView.swift
//  ColumbaApp
//
//  Map tab with full-screen MapLibre map, scale bar, and location button.
//

import SwiftUI
import RNSAPI
#if os(iOS)
import CoreLocation
#endif

@available(iOS 17.0, macOS 14.0, *)
struct MapView: View {
    var appServices: AppServices
    var mapHttpEnabled: Bool = true
    /// Cross-tab route raised by the peer contact sheet's Message button.
    /// Carries the peer's destination hash up to MainTabView, which switches
    /// to the Chats tab and hands the hash to ChatsView for opening the
    /// conversation (session-route precedent: `shouldOpenInterfaceManagement`).
    var onOpenPeerChat: ((Data) -> Void)? = nil

    private var locationSharingManager: LocationSharingManager? {
        appServices.locationSharingManager
    }

    #if os(iOS)
    @State private var centerOnUser = false
    @State private var metersPerPixel: Double = 1000
    @State private var locationAuthorized = false
    @State private var locationManager = CLLocationManager()
    @State private var authorizationDelegate: LocationAuthorizationDelegate?
    @State private var showOfflineMaps = false
    @State private var offlineMapManager = OfflineMapManager()
    @State private var showShareSheet = false
    @State private var contacts: [ConversationRecord] = []
    /// The tapped peer's hash. Non-nil presents the contact sheet and
    /// highlights the pin. Derived from the live `peerLocations` dictionary,
    /// so the sheet updates in place while telemetry keeps arriving; if the
    /// peer's entry disappears (cease, stale cleanup, removal) the sheet
    /// auto-dismisses via `onPeerGone`.
    @State private var selectedPeerHash: Data?
    /// The user's own coordinate for distance/direction math, mirrored up
    /// from the map's userLocation callback.
    @State private var userCoordinate: CLLocationCoordinate2D?
    /// Maps-app choices for the directions chooser; non-nil presents the
    /// "Apple Maps / Google Maps" picker.
    @State private var directionsProvider: [DirectionsProvider]?

    var body: some View {
        NavigationStack {
        ZStack {
            MapLibreMapView(
                centerOnUser: $centerOnUser,
                metersPerPixel: $metersPerPixel,
                selectedPeerHash: $selectedPeerHash,
                showsUserLocation: locationAuthorized,
                peerLocations: locationSharingManager.map { Array($0.peerLocations.values) } ?? [],
                httpEnabled: mapHttpEnabled,
                isDark: ThemeManager.shared.isDarkMode,
                onPeerTapped: { hash in
                    selectedPeerHash = hash
                },
                onUserLocationChanged: { coordinate in
                    userCoordinate = coordinate
                }
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    ScaleBarView(metersPerPixel: metersPerPixel)
                        .padding(.leading, 16)
                        .padding(.top, 60)
                    Spacer()

                    // Peer count badge
                    if let manager = locationSharingManager,
                       !manager.peerLocations.isEmpty {
                        Text("\(manager.peerLocations.count) peer\(manager.peerLocations.count == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.7))
                            .clipShape(Capsule())
                            .padding(.trailing, 16)
                            .padding(.top, 60)
                            // Pure-SwiftUI signal the interop suite can read even
                            // if XCUITest can't reach the MapLibre annotation view.
                            .accessibilityIdentifier("map_peer_count")
                    }
                }

                Spacer()

                HStack {
                    // Share / Stop Location button
                    let isSharing = locationSharingManager?.isSharingWithAnyone ?? false
                    Button {
                        if isSharing {
                            Task { await locationSharingManager?.stopAllSharing() }
                        } else {
                            Task { await loadContacts() }
                            showShareSheet = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isSharing ? "location.slash.fill" : "location.fill")
                                .font(.system(size: 14))
                            Text(isSharing ? "Stop Sharing" : "Share Location")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(isSharing ? .red : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(isSharing ? .red.opacity(0.15) : .blue.opacity(0.85))
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    }
                    .padding(.leading, 16)

                    Spacer()

                    VStack(spacing: 8) {
                        Button {
                            showOfflineMaps = true
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 20))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        }

                        Button {
                            requestLocationAndCenter()
                        } label: {
                            Image(systemName: "location.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        }
                        .accessibilityIdentifier("map_center_on_user")
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                }
                .padding(.bottom, 4)
            }
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Theme.backgroundPrimary.opacity(0.85), for: .tabBar)
        .onAppear {
            checkLocationAuthorization()
        }
        .navigationDestination(isPresented: $showOfflineMaps) {
            OfflineMapsScreen(mapManager: offlineMapManager)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareLocationSheet(
                contacts: contacts,
                activePeers: locationSharingManager?.activePeers ?? [],
                onStartSharing: { selected, duration in
                    for hash in selected {
                        locationSharingManager?.startSharing(with: hash, duration: duration)
                    }
                }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: Binding(
            get: { selectedPeerHash != nil && selectedPeer != nil },
            set: { if !$0 { clearPeerSelection() } }
        )) {
            peerContactSheet
        }
        .confirmationDialog(
            String(localized: "Open Directions in:"),
            isPresented: Binding(
                get: { directionsProvider != nil },
                set: { if !$0 { directionsProvider = nil } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(directionsProvider ?? []) { provider in
                Button(provider.name) {
                    let chosen = provider
                    directionsProvider = nil
                    directionsLauncher.open(chosen)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                directionsProvider = nil
            }
        }
        } // NavigationStack
    }

    // MARK: - Peer contact sheet (tappable pin)

    /// The live peer behind `selectedPeerHash`. Re-derived on every update so
    /// a newer telemetry tick refreshes the sheet in place while it is open.
    private var selectedPeer: PeerLocation? {
        guard let hash = selectedPeerHash else { return nil }
        return locationSharingManager?.peerLocations[hash]
    }

    /// Auto-dismiss when the selected peer's entry disappears from
    /// `peerLocations` (cease signal, stale cleanup, or Remove from map).
    /// `.onChange` on the derived peer's id fires when the id goes nil too.
    private var peerContactSheet: some View {
        Group {
            if let peer = selectedPeer {
                PeerContactSheet(
                    peer: peer,
                    userCoordinate: userCoordinate,
                    onDirections: { launchDirections(for: peer) },
                    onMessage: {
                        let hash = peer.id
                        clearPeerSelection()
                        onOpenPeerChat?(hash)
                    },
                    onRemove: {
                        locationSharingManager?.removePeerLocation(peer.id)
                        clearPeerSelection()
                    },
                    onDismiss: { clearPeerSelection() }
                )
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: selectedPeer?.id) { _, id in
            // The peer vanished from the live dictionary while the sheet was
            // open: lift the selection so the sheet closes itself.
            if id == nil, selectedPeerHash != nil {
                clearPeerSelection()
            }
        }
    }

    private func clearPeerSelection() {
        selectedPeerHash = nil
    }

    /// Directions button: one installed maps app → launch it directly (fewer
    /// taps); both installed → let the user choose (Apple Maps first).
    private func launchDirections(for peer: PeerLocation) {
        let coordinate = CLLocationCoordinate2D(latitude: peer.latitude, longitude: peer.longitude)
        let providers = directionsLauncher.providers(for: coordinate)
        if providers.count == 1 {
            directionsLauncher.open(providers[0])
        } else {
            directionsProvider = providers
        }
    }

    private var directionsLauncher: DirectionsLauncher {
        DirectionsLauncher()
    }

    private func loadContacts() async {
        // Read conversations from the GRDB canonical store (Track A0) via the
        // repository AppServices builds during initialize(). MapView must not
        // import LXMFSwift, so it reuses that instance instead of constructing
        // its own MessageRepository(grdbPath:).
        guard let repo = appServices.messageRepository else { return }
        contacts = (try? await repo.fetchConversations()) ?? []
    }

    private func checkLocationAuthorization() {
        let status = locationManager.authorizationStatus
        locationAuthorized = (status == .authorizedWhenInUse || status == .authorizedAlways)

        if authorizationDelegate == nil {
            let delegate = LocationAuthorizationDelegate { authorized in
                locationAuthorized = authorized
            }
            authorizationDelegate = delegate
            locationManager.delegate = delegate
        }
    }

    private func requestLocationAndCenter() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            centerOnUser = true
        }
    }

    #else
    // macOS fallback
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundPrimary
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.accentColor)
                    Text("Map")
                        .font(.screenTitle)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Map view is available on iOS")
                        .font(.bodyText)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding()
            }
            .navigationTitle("Map")
        }
    }
    #endif
}

// MARK: - Share Location Bottom Sheet

#if os(iOS)
@available(iOS 17.0, macOS 14.0, *)
private struct ShareLocationSheet: View {
    let contacts: [ConversationRecord]
    let activePeers: Set<Data>
    let onStartSharing: (Set<Data>, SharingDuration) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedHashes: Set<Data> = []
    @State private var selectedDuration: SharingDuration = {
        if let raw = UserDefaults.standard.string(forKey: "default_sharing_duration"),
           let d = SharingDuration.allCases.first(where: { $0.rawValue == raw }) {
            return d
        }
        return .oneHour
    }()

    private var filteredContacts: [ConversationRecord] {
        let unique = Dictionary(grouping: contacts, by: \.destinationHash)
            .compactMapValues(\.first).values
            .sorted { ($0.lastMessageTimestamp) > ($1.lastMessageTimestamp) }

        if searchText.isEmpty { return Array(unique) }
        return unique.filter {
            ($0.displayName ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Handle bar
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Text("Share Your Location")
                .font(.title3.bold())
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 16)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search contacts", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Selected chips
            if !selectedHashes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(contacts.filter { selectedHashes.contains($0.destinationHash) }, id: \.destinationHash) { contact in
                            HStack(spacing: 4) {
                                Text(contact.displayName ?? contact.destinationHash.prefix(4).map { String(format: "%02x", $0) }.joined())
                                    .font(.caption)
                                    .foregroundStyle(Theme.textPrimary)
                                Button {
                                    selectedHashes.remove(contact.destinationHash)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 8)
            }

            // Contact list
            List {
                ForEach(filteredContacts, id: \.destinationHash) { contact in
                    let hash = contact.destinationHash
                    let isSelected = selectedHashes.contains(hash)
                    let alreadySharing = activePeers.contains(hash)
                    Button {
                        if isSelected {
                            selectedHashes.remove(hash)
                        } else {
                            selectedHashes.insert(hash)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.displayName ?? hash.prefix(4).map { String(format: "%02x", $0) }.joined())
                                    .foregroundStyle(Theme.textPrimary)
                                if alreadySharing {
                                    Text("Already sharing")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.accentColor)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)

            Divider()

            // Duration picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Duration")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SharingDuration.allCases) { duration in
                            Button {
                                selectedDuration = duration
                            } label: {
                                Text(duration.rawValue)
                                    .font(.subheadline)
                                    .foregroundStyle(selectedDuration == duration ? .white : Theme.textPrimary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(selectedDuration == duration ? Theme.accentColor : Color(.systemGray5))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Start button
            Button {
                onStartSharing(selectedHashes, selectedDuration)
                dismiss()
            } label: {
                Text("Start Sharing")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(selectedHashes.isEmpty ? Color.gray : Theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(selectedHashes.isEmpty)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Theme.backgroundPrimary)
    }
}
#endif

// MARK: - Scale Bar

@available(iOS 17.0, macOS 14.0, *)
private struct ScaleBarView: View {
    let metersPerPixel: Double

    var body: some View {
        let (label, barWidth) = scaleBarParams()
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
            HStack(spacing: 0) {
                Rectangle()
                    .frame(width: 2, height: 6)
                Rectangle()
                    .frame(width: barWidth, height: 2)
                Rectangle()
                    .frame(width: 2, height: 6)
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func scaleBarParams() -> (String, CGFloat) {
        let niceValues: [(Double, String)] = [
            (5, "5 m"), (10, "10 m"), (20, "20 m"), (50, "50 m"),
            (100, "100 m"), (200, "200 m"), (500, "500 m"),
            (1_000, "1 km"), (2_000, "2 km"), (5_000, "5 km"),
            (10_000, "10 km"), (20_000, "20 km"), (50_000, "50 km"),
            (100_000, "100 km"), (200_000, "200 km"), (500_000, "500 km"),
            (1_000_000, "1000 km"),
        ]

        let minWidth: CGFloat = 60
        let maxWidth: CGFloat = 140

        for (meters, label) in niceValues {
            let width = CGFloat(meters / metersPerPixel)
            if width >= minWidth && width <= maxWidth {
                return (label, width)
            }
        }

        // Fallback: pick closest that fits
        for (meters, label) in niceValues.reversed() {
            let width = CGFloat(meters / metersPerPixel)
            if width >= minWidth {
                return (label, min(width, maxWidth))
            }
        }

        let (meters, label) = niceValues.first!
        return (label, max(CGFloat(meters / metersPerPixel), minWidth))
    }
}

// MARK: - Location Authorization Delegate

#if os(iOS)
private final class LocationAuthorizationDelegate: NSObject, CLLocationManagerDelegate {
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        onChange(status == .authorizedWhenInUse || status == .authorizedAlways)
    }
}
#endif

// MARK: - Preview

#if DEBUG
@available(iOS 17.0, macOS 14.0, *)
#Preview {
    MapView(appServices: AppServices())
        .preferredColorScheme(.dark)
}
#endif
