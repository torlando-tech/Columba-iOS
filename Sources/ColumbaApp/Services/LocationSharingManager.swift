//
//  LocationSharingManager.swift
//  ColumbaApp
//
//  Core location sharing service for Sideband-compatible telemetry exchange.
//  Manages CLLocationManager for GPS, periodic sending to active peers,
//  and tracking incoming peer locations for map display.
//

import Foundation
import CoreLocation
import LXMFSwift
import ReticulumSwift
import os.log

// MARK: - PeerLocation

/// A peer's most recent location for map display.
public struct PeerLocation: Identifiable, Equatable {
    /// Peer destination hash (16 bytes).
    public let id: Data

    /// Display name (from announce or conversation).
    public var displayName: String?

    /// Latitude in degrees.
    public var latitude: Double

    /// Longitude in degrees.
    public var longitude: Double

    /// Altitude in meters.
    public var altitude: Double

    /// Speed in m/s.
    public var speed: Double

    /// Bearing in degrees.
    public var bearing: Double

    /// Horizontal accuracy in meters.
    public var accuracy: Double

    /// When this location was received.
    public var lastUpdate: Date

    /// True if older than 5 minutes.
    public var isStale: Bool {
        Date().timeIntervalSince(lastUpdate) > 300
    }

    /// Short hex identifier for display.
    public var shortHash: String {
        id.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - LocationSharingManager

/// Manages bidirectional location sharing with peers via LXMF telemetry.
///
/// - Sends location updates as `FIELD_TELEMETRY` in LXMF messages to active peers
/// - Receives incoming telemetry and updates `peerLocations` for map display
/// - Matches Sideband's 60s foreground / 300s background intervals
@available(iOS 17.0, macOS 14.0, *)
@Observable
@MainActor
public final class LocationSharingManager: NSObject {

    // MARK: - Observable Properties

    /// Peers we are actively sharing location with (destination hashes).
    public private(set) var activePeers: Set<Data> = []

    /// Received peer locations for map display.
    public private(set) var peerLocations: [Data: PeerLocation] = [:]

    /// True if sharing with at least one peer.
    public var isSharingWithAnyone: Bool { !activePeers.isEmpty }

    // MARK: - Dependencies

    /// Weak reference to AppServices (avoids retain cycle).
    private weak var appServices: AppServices?

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.columba.app", category: "LocationSharing")
    private let locationManager = CLLocationManager()
    private var sendTimer: Timer?
    private var lastSentLocation: CLLocation?
    private var lastSentTime: Date?
    private var isInBackground = false

    // MARK: - Constants

    /// Foreground send interval (seconds).
    private static let foregroundInterval: TimeInterval = 60

    /// Background send interval (seconds).
    private static let backgroundInterval: TimeInterval = 300

    /// Minimum movement to trigger update (meters).
    private static let minMovement: Double = 4.0

    /// Maximum acceptable accuracy (meters).
    private static let accuracyCutoff: Double = 250.0

    /// GPS stale threshold (seconds).
    private static let staleThreshold: TimeInterval = 15.0

    /// UserDefaults key for persisted active peers.
    private static let activePeersKey = "locationSharing_activePeers"

    // MARK: - Initialization

    /// Create LocationSharingManager.
    ///
    /// - Parameter appServices: AppServices for router and identity access
    public init(appServices: AppServices) {
        self.appServices = appServices
        super.init()
        loadPersistedPeers()
    }

    // MARK: - Public API

    /// Start sharing location with a peer.
    ///
    /// - Parameter peerHash: 16-byte destination hash of the peer
    public func startSharing(with peerHash: Data) {
        activePeers.insert(peerHash)
        persistActivePeers()

        if activePeers.count == 1 {
            startLocationUpdates()
            startSendTimer()
        }

        // Send initial update immediately
        Task {
            await sendLocationUpdateToPeer(peerHash)
        }

        let hex = peerHash.prefix(4).map { String(format: "%02x", $0) }.joined()
        logger.info("Started sharing location with \(hex)")
    }

    /// Stop sharing location with a peer, sending cease signal.
    ///
    /// - Parameter peerHash: 16-byte destination hash of the peer
    public func stopSharing(with peerHash: Data) {
        activePeers.remove(peerHash)
        persistActivePeers()

        // Send cease signal
        Task {
            await sendCeaseSignal(to: peerHash)
        }

        if activePeers.isEmpty {
            stopLocationUpdates()
            stopSendTimer()
        }

        let hex = peerHash.prefix(4).map { String(format: "%02x", $0) }.joined()
        logger.info("Stopped sharing location with \(hex)")
    }

    /// Stop sharing with all peers, sending cease signals.
    public func stopAllSharing() {
        let peers = activePeers
        for peer in peers {
            stopSharing(with: peer)
        }
    }

    /// Check if currently sharing with a specific peer.
    ///
    /// - Parameter peerHash: 16-byte destination hash
    /// - Returns: True if sharing is active for this peer
    public func isSharing(with peerHash: Data) -> Bool {
        activePeers.contains(peerHash)
    }

    /// Handle incoming telemetry from a peer.
    ///
    /// - Parameters:
    ///   - peerHash: Source destination hash
    ///   - packet: Decoded telemetry packet
    ///   - displayName: Optional display name for the peer
    public func handleIncomingTelemetry(from peerHash: Data, packet: TelemetryPacket, displayName: String?) {
        guard let location = packet.location else { return }

        if location.isCeased {
            // Peer stopped sharing — remove marker
            peerLocations.removeValue(forKey: peerHash)
            let hex = peerHash.prefix(4).map { String(format: "%02x", $0) }.joined()
            logger.info("Peer \(hex) ceased location sharing")
            return
        }

        let peerLoc = PeerLocation(
            id: peerHash,
            displayName: displayName,
            latitude: location.latitude,
            longitude: location.longitude,
            altitude: location.altitude,
            speed: location.speed,
            bearing: location.bearing,
            accuracy: location.accuracy,
            lastUpdate: Date(timeIntervalSince1970: TimeInterval(location.lastUpdate))
        )

        peerLocations[peerHash] = peerLoc

        let hex = peerHash.prefix(4).map { String(format: "%02x", $0) }.joined()
        logger.info("Updated peer \(hex) location: \(location.latitude), \(location.longitude)")
    }

    /// Update foreground/background state to adjust send interval.
    ///
    /// - Parameter inBackground: True if app is in background
    public func setBackgroundState(_ inBackground: Bool) {
        guard isInBackground != inBackground else { return }
        isInBackground = inBackground

        if isSharingWithAnyone {
            stopSendTimer()
            startSendTimer()

            if inBackground {
                locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                locationManager.allowsBackgroundLocationUpdates = true
            } else {
                locationManager.desiredAccuracy = kCLLocationAccuracyBest
                locationManager.allowsBackgroundLocationUpdates = false
            }
        }
    }

    /// Clean up when shutting down.
    public func shutdown() {
        stopAllSharing()
        stopLocationUpdates()
        stopSendTimer()
    }

    // MARK: - Location Manager

    private func startLocationUpdates() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = Self.minMovement

        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }

        locationManager.startUpdatingLocation()
        logger.info("Started location updates")
    }

    private func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
        locationManager.delegate = nil
        logger.info("Stopped location updates")
    }

    // MARK: - Send Timer

    private func startSendTimer() {
        let interval = isInBackground ? Self.backgroundInterval : Self.foregroundInterval
        sendTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sendLocationToAllPeers()
            }
        }
        logger.info("Send timer started with interval: \(interval)s")
    }

    private func stopSendTimer() {
        sendTimer?.invalidate()
        sendTimer = nil
    }

    // MARK: - Sending

    private func sendLocationToAllPeers() async {
        for peer in activePeers {
            await sendLocationUpdateToPeer(peer)
        }
    }

    private func sendLocationUpdateToPeer(_ peerHash: Data) async {
        guard let appServices = appServices,
              let identity = appServices.identity,
              let router = appServices.router else {
            return
        }

        // Get current location
        guard let location = locationManager.location else {
            logger.info("No location available, skipping send")
            return
        }

        // Check accuracy cutoff
        guard location.horizontalAccuracy <= Self.accuracyCutoff else {
            logger.info("Accuracy \(location.horizontalAccuracy)m exceeds cutoff, skipping")
            return
        }

        // Check minimum movement
        if let lastSent = lastSentLocation,
           location.distance(from: lastSent) < Self.minMovement {
            // Check if GPS data is stale
            if let lastTime = lastSentTime,
               Date().timeIntervalSince(lastTime) < Self.staleThreshold {
                return
            }
        }

        // Build telemetry packet
        let telemetry = LocationTelemetry(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            speed: max(0, location.speed),
            bearing: max(0, location.course),
            accuracy: location.horizontalAccuracy,
            lastUpdate: Int(location.timestamp.timeIntervalSince1970)
        )

        let packet = TelemetryPacket(
            timestamp: Int(Date().timeIntervalSince1970),
            location: telemetry
        )

        // Encode telemetry as FIELD_TELEMETRY bytes
        let telemetryData = packet.encode()

        // Build and send LXMF message with telemetry field
        var fields: [UInt8: Any] = [:]
        fields[LXMessage.FIELD_TELEMETRY] = telemetryData

        var lxMessage = LXMessage(
            destinationHash: peerHash,
            sourceIdentity: identity,
            content: Data(),  // No text content for telemetry-only messages
            title: Data(),
            fields: fields,
            desiredMethod: .opportunistic
        )

        do {
            try await router.handleOutbound(&lxMessage)
            lastSentLocation = location
            lastSentTime = Date()

            let hex = peerHash.prefix(4).map { String(format: "%02x", $0) }.joined()
            logger.info("Sent location to \(hex): \(telemetry.latitude), \(telemetry.longitude)")
        } catch {
            logger.warning("Failed to send location: \(error.localizedDescription)")
        }
    }

    private func sendCeaseSignal(to peerHash: Data) async {
        guard let appServices = appServices,
              let identity = appServices.identity,
              let router = appServices.router else {
            return
        }

        let cease = LocationTelemetry.ceaseSignal()
        let packet = TelemetryPacket(timestamp: 0, location: cease)
        let telemetryData = packet.encode()

        var fields: [UInt8: Any] = [:]
        fields[LXMessage.FIELD_TELEMETRY] = telemetryData

        var lxMessage = LXMessage(
            destinationHash: peerHash,
            sourceIdentity: identity,
            content: Data(),
            title: Data(),
            fields: fields,
            desiredMethod: .opportunistic
        )

        do {
            try await router.handleOutbound(&lxMessage)
            let hex = peerHash.prefix(4).map { String(format: "%02x", $0) }.joined()
            logger.info("Sent cease signal to \(hex)")
        } catch {
            logger.warning("Failed to send cease signal: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    private func persistActivePeers() {
        let hexArray = activePeers.map { $0.map { String(format: "%02x", $0) }.joined() }
        UserDefaults.standard.set(hexArray, forKey: Self.activePeersKey)
    }

    private func loadPersistedPeers() {
        guard let hexArray = UserDefaults.standard.stringArray(forKey: Self.activePeersKey) else {
            return
        }

        for hex in hexArray {
            if let data = Data(hexString: hex) {
                activePeers.insert(data)
            }
        }

        if !activePeers.isEmpty {
            startLocationUpdates()
            startSendTimer()
        }
    }
}

// MARK: - CLLocationManagerDelegate

@available(iOS 17.0, macOS 14.0, *)
extension LocationSharingManager: CLLocationManagerDelegate {
    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // CLLocationManagerDelegate callbacks are on main thread already
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                if isSharingWithAnyone {
                    manager.startUpdatingLocation()
                }
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            logger.warning("Location error: \(error.localizedDescription)")
        }
    }
}

