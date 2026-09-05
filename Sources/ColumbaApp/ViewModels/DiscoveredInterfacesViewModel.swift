//
//  DiscoveredInterfacesViewModel.swift
//  ColumbaApp
//
//  ViewModel for the discovered interfaces screen (RNS 1.1.x discovery).
//  Port of Android's DiscoveredInterfacesViewModel (issue #193): shows the
//  interfaces announced by other nodes, with search / type-chip / IFAC-only
//  DISPLAY filters, proximity sorting, and the discovery + autoconnect
//  settings (persisted to SettingsRepository and applied through a real
//  in-process backend restart).
//
//  All pure sort / filter / haversine logic lives in RNSAPI (T-A:
//  DiscoveredSorter, DiscoveredFilter, haversineDistanceKm) — this VM only
//  orchestrates UI state.
//

import Foundation
import RNSAPI
import SwiftUI
import os.log

private let logger = Logger(subsystem: "network.columba.Columba", category: "DiscoveredIfacesVM")

// MARK: - Discovered Interfaces ViewModel

/// ViewModel for the discovered interfaces screen.
///
/// Manages the visible (filtered + sorted) interface list, the raw backend
/// list, search / type / IFAC display filters, the user location for
/// distance display, and the discovery + autoconnect settings. Toggling the
/// settings persists them, then applies them via
/// `appServices.restartPythonBackend()` (in-process restart +
/// `ColumbaBackendRestarted`), then re-polls live discovery state.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class DiscoveredInterfacesViewModel {

    // MARK: - Dependencies

    private let appServices: AppServices
    private let settings: SettingsRepository

    // MARK: - List State

    /// Interfaces currently visible (display-filtered + sorted).
    public var interfaces: [DiscoveredInterface] = []

    /// Raw list from the backend, before display filters — the source for
    /// re-filtering when the user changes search / type / IFAC filters.
    public var originalInterfaces: [DiscoveredInterface] = []

    /// Whether the discovery list is loading.
    public var isLoading: Bool = true

    /// Whether a discovery-settings change is being applied (backend restart).
    public var isRestarting: Bool = false

    /// Current error message (set on load / apply failures).
    public var errorMessage: String?

    /// Count of discovered interfaces in each status bucket.
    public var availableCount: Int = 0
    public var unknownCount: Int = 0
    public var staleCount: Int = 0

    // MARK: - Display Filters

    /// Sort mode for the interface list.
    public var sortMode: DiscoveredSortMode = .availabilityAndQuality

    /// Free-form search filter, matched against name + reachableOn + type.
    public var searchQuery: String = ""

    /// Multi-select type filter. Empty set = no filtering (all types shown).
    public var typeFilters: Set<DiscoveredTypeFilter> = []

    /// When true, only show interfaces that announced an IFAC network name.
    public var ifacOnly: Bool = false

    // MARK: - User Location

    /// The user's current location for distance calculation (nil = unknown).
    public var userLatitude: Double?
    public var userLongitude: Double?

    // MARK: - Discovery Settings (persisted preferences + runtime state)

    /// User preference: the interface-discovery master switch (persisted).
    public var discoverInterfacesEnabled: Bool = false

    /// User preference: max discovered interfaces to autoconnect (persisted).
    public var autoconnectCount: Int = 0

    /// Runtime state: whether the running backend has discovery enabled.
    public var isDiscoveryEnabled: Bool = false

    /// Endpoints ("host:port") the backend has autoconnected to.
    public var autoconnectedEndpoints: Set<String> = []

    /// Names of the bootstrap-only TCP client interfaces (they enable discovery).
    public var bootstrapInterfaceNames: [String] = []

    // MARK: - Private State

    /// Observer token for `ColumbaBackendRestarted` — re-polls the list
    /// whenever the backend restarts from anywhere (settings toggle here,
    /// transport toggle, test deep-link).
    private var backendRestartObserver: NSObjectProtocol?

#if os(iOS)
    /// Retains the active one-shot location provider. The provider owns its
    /// `CLLocationManager`, but nothing else retains the provider (the
    /// manager→delegate edge is weak), so a local in `requestUserLocation()`
    /// would deallocate at method exit and the fix/timeout could never
    /// deliver. Released from the provider's completion once delivered.
    private var locationProvider: OneShotLocationProvider?
#endif

    // MARK: - Initialization

    public init(appServices: AppServices, settings: SettingsRepository) {
        self.appServices = appServices
        self.settings = settings
        startBackendRestartObserver()
        load()
    }

    deinit {
        if let observer = backendRestartObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Loading

    /// Kick off an initial load (called from init; mirrors the house
    /// `Task { @MainActor in }` spawn pattern).
    public func load() {
        Task { @MainActor in
            await self.loadAsync()
        }
    }

    /// Load discovered interfaces from the running RNS backend, plus the
    /// persisted discovery settings, then recompute the visible list.
    @MainActor
    public func loadAsync() async {
        isLoading = true
        errorMessage = nil

        // `pythonBackend` is compiled only into the shipping (Python) build;
        // Model B has no app-side discovery — show an honest message instead
        // of a nil-unwrap crash.
        let snapshot: DiscoverySnapshot?
        #if COLUMBA_RUNTIME_PYTHON
        snapshot = await appServices.pythonBackend?.discovery()
        #else
        snapshot = nil
        #endif

        guard let snapshot else {
            isLoading = false
            errorMessage = String(localized: "Interface discovery is unavailable in this build.")
            logger.warning("Discovery unavailable — no Python backend")
            return
        }

        originalInterfaces = snapshot.discovered
        availableCount = snapshot.discovered.filter { $0.status == "available" }.count
        unknownCount = snapshot.discovered.filter { $0.status == "unknown" }.count
        staleCount = snapshot.discovered.filter { $0.status == "stale" }.count
        isDiscoveryEnabled = snapshot.enabled
        autoconnectedEndpoints = Set(snapshot.autoconnected)

        await loadSettings()
        recomputeVisible()
        isLoading = false

        logger.info("Loaded \(snapshot.discovered.count) discovered interfaces, \(autoconnectedEndpoints.count) auto-connected")
    }

    /// Load discovery settings (persisted preferences) and the bootstrap-only
    /// interface names.
    @MainActor
    public func loadSettings() async {
        discoverInterfacesEnabled = await settings.getDiscoverInterfacesEnabled()

        let saved = await settings.getAutoconnectDiscoveredCount()
        // 0 doubles as the "never configured" sentinel — the UI defaults to
        // 3 in toggleDiscovery() on first enable (mirror of Android).
        autoconnectCount = saved >= 0 ? saved : 0

        // Synchronous, non-actor-isolated house pattern: InterfaceRepository
        // is a plain final class (see the direct call sites in AppServices).
        bootstrapInterfaceNames = InterfaceRepository()
            .getEnabledInterfaces()
            .filter { entity in
                guard case .tcpClient(let config) = entity.config else { return false }
                return config.bootstrapOnly
            }
            .map { $0.name }
    }

    /// Recompute the visible list from the raw backend list + the current
    /// display filters. Pure logic is delegated to RNSAPI (T-A).
    private func recomputeVisible() {
        interfaces = DiscoveredSorter.sort(
            DiscoveredFilter.apply(
                originalInterfaces,
                searchQuery: searchQuery,
                typeFilters: typeFilters,
                ifacOnly: ifacOnly
            ),
            mode: sortMode,
            userLatitude: userLatitude,
            userLongitude: userLongitude
        )
    }

    // MARK: - Search / Filter / Sort Mutators

    /// Update the free-form search query and recompute the visible list.
    public func setSearchQuery(_ query: String) {
        searchQuery = query
        recomputeVisible()
    }

    /// Insert or remove a type chip and recompute the visible list.
    public func toggleTypeFilter(_ filter: DiscoveredTypeFilter) {
        if typeFilters.contains(filter) {
            typeFilters.remove(filter)
        } else {
            typeFilters.insert(filter)
        }
        recomputeVisible()
    }

    /// Toggle the IFAC-only display filter and recompute the visible list.
    public func toggleIfacOnlyFilter() {
        ifacOnly.toggle()
        recomputeVisible()
    }

    /// Clear all display filters and recompute the visible list.
    public func clearFilters() {
        searchQuery = ""
        typeFilters = []
        ifacOnly = false
        recomputeVisible()
    }

    /// Switch sort mode. Switching to `.proximity` is IGNORED (stay in the
    /// current mode) while the user location is unknown — mirror of the
    /// Android guard.
    public func setSortMode(_ mode: DiscoveredSortMode) {
        if mode == .proximity, userLatitude == nil || userLongitude == nil {
            logger.info("Ignoring proximity sort request — no user location fix yet")
            return
        }
        sortMode = mode
        recomputeVisible()
    }

    // MARK: - User Location

    /// Record the user's current location so distances can be shown; re-sorts
    /// when in proximity mode.
    public func setUserLocation(lat: Double, lon: Double) {
        userLatitude = lat
        userLongitude = lon
        if sortMode == .proximity {
            recomputeVisible()
        }
    }

    /// Fetch the user's current location with a one-shot GPS fix (bounded
    /// ~10s, never prompts for permission). On a fix, records it via
    /// `setUserLocation(lat:lon:)`.
    @MainActor
    public func requestUserLocation() {
        #if os(iOS)
        let provider = OneShotLocationProvider { [weak self] coordinate in
            // Release the one-shot provider now that the fix (or timeout)
            // has delivered, so the manager deallocates and GPS acquisition
            // is fully dropped. Only if still the active provider — a newer
            // request may already have replaced us.
            if self?.locationProvider === provider {
                self?.locationProvider = nil
            }
            guard let coordinate else { return }
            self?.setUserLocation(lat: coordinate.latitude, lon: coordinate.longitude)
        }
        locationProvider = provider
        provider.request()
        #endif
    }

    // MARK: - Distance / Autoconnect

    /// Distance in km from the user to an interface, or nil when either
    /// location is unknown. Pure haversine math lives in RNSAPI (T-A).
    public func calculateDistance(_ iface: DiscoveredInterface) -> Double? {
        guard let userLatitude, let userLongitude,
              iface.hasLocation,
              let lat = iface.latitude,
              let lon = iface.longitude else {
            return nil
        }
        return haversineDistanceKm(lat1: userLatitude, lon1: userLongitude, lat2: lat, lon2: lon)
    }

    /// Whether the backend has autoconnected to this interface's endpoint.
    public func isAutoconnected(_ iface: DiscoveredInterface) -> Bool {
        guard !autoconnectedEndpoints.isEmpty,
              let host = iface.reachableOn,
              let port = iface.port else {
            return false
        }
        return autoconnectedEndpoints.contains("\(host):\(port)")
    }

    // MARK: - Discovery Settings (persist + in-process restart)

    /// Toggle interface discovery on/off.
    ///
    /// When enabling: restores the user's saved autoconnect preference (or
    /// defaults to 3 on first enable). When disabling: the UI shows 0 but the
    /// saved preference is NOT overwritten (preserved for the next enable).
    /// Persists to settings, applies via the real in-process backend restart
    /// (T-D), then re-polls live discovery state once back up.
    public func toggleDiscovery() {
        let newEnabled = !discoverInterfacesEnabled
        let newCount: Int
        if newEnabled {
            // Restore the user's saved preference, or default 3 on first enable.
            let saved = autoconnectCount   // already loaded by loadSettings
            newCount = saved > 0 ? saved : 3
        } else {
            newCount = 0   // UI shows 0; we do NOT persist 0 (preserve preference)
        }

        // Update the UI immediately to show the restarting state.
        discoverInterfacesEnabled = newEnabled
        autoconnectCount = newEnabled ? newCount : 0
        isRestarting = true

        Task { @MainActor in
            await settings.setDiscoverInterfacesEnabled(newEnabled)
            // Only persist the count when enabling (preserve the user's
            // preference when disabling).
            if newEnabled {
                await settings.setAutoconnectDiscoveredCount(newCount)
            }
            // Rewrites the config (fresh discovery settings, T-C) and does
            // the real in-process restart (T-D), posting
            // `ColumbaBackendRestarted` on success.
            await appServices.restartPythonBackend()
            await loadAsync()   // re-poll live discovery state once back up
            isRestarting = false
        }
    }

    /// Set the number of discovered interfaces to autoconnect (clamped 0-10).
    /// Persists, applies via the in-process restart, then re-polls.
    public func setAutoconnectCount(_ count: Int) {
        let clamped = min(max(count, 0), 10)
        autoconnectCount = clamped
        isRestarting = true
        Task { @MainActor in
            await settings.setAutoconnectDiscoveredCount(clamped)
            await appServices.restartPythonBackend()
            await loadAsync()
            isRestarting = false
        }
    }

    // MARK: - Backend Restart Observation

    /// Re-poll whenever the backend restarts from anywhere, so a restart
    /// driven by the transport toggle or a test deep-link refreshes this
    /// list (house pattern: token stored, removed in deinit).
    private func startBackendRestartObserver() {
        backendRestartObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("ColumbaBackendRestarted"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.loadAsync()
            }
        }
    }
}
