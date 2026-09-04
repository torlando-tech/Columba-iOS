//
//  OneShotLocationProvider.swift
//  ColumbaApp
//
//  Minimal one-shot CoreLocation wrapper for the discovered-interfaces
//  screen (issue #193). The VM needs the user's current coordinates to
//  enable distance display / proximity sort, but must NOT trigger a fresh
//  "allow location" permission prompt from that screen: if authorization
//  is not already granted (.whenInUse / .always) this provider simply
//  delivers `nil` and never calls `requestWhenInUseAuthorization()`.
//
//  Bounded: a fix that does not arrive within ~10s delivers `nil` so the
//  calling screen can never hang. Completion always runs on the main
//  actor.
//

#if os(iOS)
import Foundation
import CoreLocation

/// Delivers a single one-shot location fix (or `nil`) without ever
/// prompting for location permission.
///
/// Mirrors the house CoreLocation pattern in `LocationSharingManager`
/// (`NSObject` + `CLLocationManagerDelegate`, manager held as a property
/// so delegate callbacks fire, delegate methods `nonisolated` with the
/// `Task { @MainActor in }` hop — delegate callbacks already arrive on
/// the main thread).
@available(iOS 17.0, macOS 14.0, *)
final class OneShotLocationProvider: NSObject, CLLocationManagerDelegate {

    /// One-shot fix deadline (seconds). GPS cold starts can take several
    /// seconds; 10s keeps the UI responsive without cutting off a fix
    /// that would arrive shortly.
    private static let timeout: TimeInterval = 10

    /// Deliver the first fix, or `nil` (unauthorized / error / timeout).
    /// Always called exactly once, on the main actor.
    private let completion: (CLLocationCoordinate2D?) -> Void

    /// Retained for the lifetime of the one-shot request — `requestLocation`
    /// requires a live manager to deliver its delegate callbacks.
    private let manager: CLLocationManager

    /// Guards against double-delivery (fix arriving after the timeout
    /// fired, or an error racing the timeout).
    private var delivered = false

    /// Create a provider. Call `request()` to start the one-shot fix.
    ///
    /// - Parameter completion: Called exactly once, on the main actor,
    ///   with the first fix's coordinates or `nil`.
    @MainActor
    init(completion: @escaping @MainActor (CLLocationCoordinate2D?) -> Void) {
        self.completion = completion
        self.manager = CLLocationManager()
        super.init()
        self.manager.delegate = self
        self.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Start the one-shot location request. No permission prompt is ever
    /// shown: unauthorized statuses deliver `nil` immediately.
    @MainActor
    func request() {
        switch CLLocationManager.authorizationStatus() {
        case .whenInUse, .always:
            startTimeout()
            manager.requestLocation()
        case .denied, .restricted, .notDetermined:
            // Never prompt from the discovery screen (spec assumption 6).
            deliver(nil)
        @unknown default:
            deliver(nil)
        }
    }

    // MARK: - Delivery

    @MainActor
    private func deliver(_ coordinate: CLLocationCoordinate2D?) {
        guard !delivered else { return }
        delivered = true
        manager.stopLocationUpdates()
        completion(coordinate)
    }

    /// Bound the request so a never-arriving fix can't hang the screen.
    @MainActor
    private func startTimeout() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(OneShotLocationProvider.timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.deliver(nil)
        }
    }

    // MARK: - CLLocationManagerDelegate

    /// First fix: deliver it, then stop. Delegate callbacks are on the
    /// main thread already (house pattern — see LocationSharingManager).
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        Task { @MainActor [weak self] in
            self?.deliver(CLLocationCoordinate2D(latitude: location.coordinate.latitude,
                                                longitude: location.coordinate.longitude))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.deliver(nil)
        }
    }
}
#endif
