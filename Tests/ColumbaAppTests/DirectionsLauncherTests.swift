//
//  DirectionsLauncherTests.swift
//  ColumbaAppTests
//
//  Pins the directions-provider listing: Apple Maps is always offered,
//  Google Maps only when its scheme probe reports installed, and the
//  Google deep link carries daddr + walking mode. The probe seam makes
//  the chooser logic unit-testable without UIApplication.
//

#if os(iOS)
import CoreLocation
import XCTest
@testable import ColumbaApp

@available(iOS 17.0, *)
final class DirectionsLauncherTests: XCTestCase {

    /// Fixed probe whose answer is scripted per scheme.
    final class FixedProbe: DirectionsLauncher.SchemeProbe {
        let installed: Set<String>
        init(installed: Set<String>) { self.installed = installed }
        func canOpen(scheme: String) -> Bool { installed.contains(scheme) }
    }

    private let coordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

    func test_apple_maps_always_listed_first() {
        let launcher = DirectionsLauncher(probe: FixedProbe(installed: []))
        let providers = launcher.providers(for: coordinate)
        XCTAssertEqual(providers.map(\.id), ["apple"])
        XCTAssertEqual(providers[0].name, "Apple Maps")
    }

    func test_google_maps_listed_second_only_when_installed() {
        let withGoogle = DirectionsLauncher(probe: FixedProbe(installed: ["comgooglemaps"]))
        XCTAssertEqual(withGoogle.providers(for: coordinate).map(\.id), ["apple", "google"])

        let withoutGoogle = DirectionsLauncher(probe: FixedProbe(installed: []))
        XCTAssertEqual(withoutGoogle.providers(for: coordinate).map(\.id), ["apple"])
    }

    func test_google_maps_deep_link_covers_destination_and_walking_mode() {
        let url = DirectionsLauncher.googleMapsURL(for: coordinate)
        XCTAssertEqual(url.absoluteString, "comgooglemaps://?daddr=37.7749,-122.4194&directionsmode=walking")
    }

    func test_provider_urls() {
        let launcher = DirectionsLauncher(probe: FixedProbe(installed: ["comgooglemaps"]))
        let providers = launcher.providers(for: coordinate)
        XCTAssertNil(providers[0].url) // Apple Maps launches via MapKit
        XCTAssertEqual(providers[1].url, DirectionsLauncher.googleMapsURL(for: coordinate))
    }
}
#endif
