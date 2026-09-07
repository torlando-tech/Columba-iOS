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
/// distance display, and the discovery + autoconnect settings.
///
/// Settings are PENDING-STATE, not immediate (issue #193): the toggle and
/// the slider (which fires on every drag tick) only mutate the pending
/// values. The single `applyDiscoverySettings()` intent is the ONLY path
/// that persists them and calls `appServices.restartPythonBackend()`
/// (config rewrite + in-process restart + `ColumbaBackendRestarted`).
/// Applying immediately on every change restarted Reticulum mid-drag, and
/// each transient not-started poll emptied the list and flipped the
/// "enabled" indicator — the controls now wait for an explicit
/// "Apply and Restart".
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

    // MARK: - Pending discovery settings (apply-and-restart flow, issue #193)

    /// Snapshot of the discovery toggle value that is currently LIVE on the
    /// running backend (last successfully applied / loaded from settings).
    /// Pending changes are held in `discoverInterfacesEnabled` and compared
    /// against this to derive `hasPendingDiscoveryChanges`.
    private(set) var appliedDiscoverInterfacesEnabled: Bool = false

    /// Snapshot of the auto-connect count currently LIVE on the running
    /// backend (last successfully applied / loaded from settings).
    private(set) var appliedAutoconnectCount: Int = 0

    /// True when the pending settings differ from what the running backend
    /// has applied — the "Apply and Restart" button shows while this is set.
    public var hasPendingDiscoveryChanges: Bool {
        discoverInterfacesEnabled != appliedDiscoverInterfacesEnabled
            || autoconnectCount != appliedAutoconnectCount
    }

    /// Whether `loadSettings()` has seeded the pending settings once (guards
    /// re-polls from clobbering in-flight pending changes).
    private var hasLoadedDiscoverySettings = false

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
    /// Monotonic request generation — the completion releases the provider
    /// slot only if its own request is still the newest (a late timeout from
    /// an earlier request must not clobber a newer in-flight provider). A
    /// generation counter is used instead of capturing the provider itself
    /// because the completion closure cannot reference the `let` it
    /// initializes.
    private var locationRequestGeneration = 0
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

        let endpointCount = autoconnectedEndpoints.count
        logger.info("Loaded \(snapshot.discovered.count) discovered interfaces, \(endpointCount) auto-connected")
    }

    /// Load discovery settings (persisted preferences) and the bootstrap-only
    /// interface names.
    ///
    /// The persisted values seed the pending settings ONLY on the first load
    /// (which also establishes the applied baseline — the startup config is
    /// always written from these same settings, so persisted == live at that
    /// point). Later re-polls (refresh button, backend-restarted
    /// notification) must NOT clobber in-flight pending changes the user has
    /// made but not applied yet.
    @MainActor
    public func loadSettings() async {
        if !hasLoadedDiscoverySettings {
            discoverInterfacesEnabled = await settings.getDiscoverInterfacesEnabled()

            let saved = await settings.getAutoconnectDiscoveredCount()
            // 0 doubles as the "never configured" sentinel — enabling from
            // off defaults the pending count to 3 (setDiscoverInterfacesEnabled,
            // mirror of Android).
            autoconnectCount = saved >= 0 ? saved : 0

            appliedDiscoverInterfacesEnabled = discoverInterfacesEnabled
            appliedAutoconnectCount = autoconnectCount
            hasLoadedDiscoverySettings = true
        }

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
        locationRequestGeneration += 1
        let generation = locationRequestGeneration
        let provider = OneShotLocationProvider { [weak self] coordinate in
            // Release the one-shot provider now that the fix (or timeout)
            // has delivered, so the manager deallocates and GPS acquisition
            // is fully dropped — but only if this request is still the
            // newest (a late timeout from a superseded request must not
            // clobber a newer in-flight provider).
            if let self, self.locationRequestGeneration == generation {
                self.locationProvider = nil
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

    // MARK: - Discovery Settings (pending state + apply-and-restart)

    /// Toggle the pending discovery value. Pure pending state — does NOT
    /// persist and does NOT restart; the user confirms with "Apply and
    /// Restart" (`applyDiscoverySettings`). Enabling from off with a
    /// never-configured count (0 sentinel) defaults the count to 3
    /// (Android mirror) — the user still sees and can change the pending
    /// value before applying.
    public func setDiscoverInterfacesEnabled(_ enabled: Bool) {
        discoverInterfacesEnabled = enabled
        if enabled && autoconnectCount == 0 {
            autoconnectCount = 3
        }
    }

    /// Set the pending auto-connect count (clamped 0-10). Pure pending
    /// state — does NOT persist and does NOT restart (the SwiftUI slider
    /// fires this on every drag tick; the single apply button is the only
    /// restart trigger). A count of 0 keeps discovery ENABLED
    /// (observe-only mode: heard announces are still recorded and listed,
    /// just nothing is auto-connected).
    public func setAutoconnectCount(_ count: Int) {
        autoconnectCount = min(max(count, 0), 10)
    }

    /// Persist the pending discovery settings and apply them via the real
    /// in-process backend restart. `restartPythonBackend` rewrites the RNS
    /// config from the persisted settings (T-C), tears the backend down,
    /// re-inits it, and posts `ColumbaBackendRestarted` on success — which
    /// the observer turns into a re-poll of the live discovery state.
    ///
    /// The applied snapshots are committed only on a SUCCESSFUL restart. On
    /// failure the backend is down: the settings were persisted (so a
    /// future restart picks them up) but are NOT live, so the pending flag
    /// stays set (button remains tappable to retry) and an error is
    /// surfaced. The user's in-flight control values are never clobbered.
    @MainActor
    public func applyDiscoverySettings() async {
        guard hasPendingDiscoveryChanges, !isRestarting else { return }

        let toEnable = discoverInterfacesEnabled
        let toCount = autoconnectCount

        isRestarting = true
        errorMessage = nil
        // Persist first so the config rewrite inside restartPythonBackend
        // reads the fresh values.
        await settings.setDiscoverInterfacesEnabled(toEnable)
        await settings.setAutoconnectDiscoveredCount(toCount)

        let succeeded = await appServices.restartPythonBackend()

        if succeeded {
            // Commit: pending == applied from here on; the
            // `ColumbaBackendRestarted` re-poll refreshes the list, the
            // status dot, and the corrected `enabled` flag from the bridge.
            appliedDiscoverInterfacesEnabled = toEnable
            appliedAutoconnectCount = toCount
        } else {
            errorMessage = String(localized: "Restart failed — discovery settings were not applied.")
            logger.error("Discovery settings apply failed (restart error); pending flag kept for retry")
        }
        isRestarting = false
    }

    /// Revert the pending settings to what the running backend has applied.
    public func discardPendingDiscoveryChanges() {
        discoverInterfacesEnabled = appliedDiscoverInterfacesEnabled
        autoconnectCount = appliedAutoconnectCount
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
