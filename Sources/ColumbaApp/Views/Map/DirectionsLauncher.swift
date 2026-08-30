//
//  DirectionsLauncher.swift
//  ColumbaApp
//
//  Decides which maps apps can open a walking directions route to a peer
//  location and how to launch them. Apple Maps is always available (launched
//  through MapKit in walking mode, matching Android); Google Maps appears
//  only when its documented `comgooglemaps://` scheme is installed, which
//  requires the `LSApplicationQueriesSchemes` entry in Info.plist for
//  `canOpenURL` to report it. Adding a third provider (e.g. an
//  OpenStreetMaps app) is one entry in `providers(for:)`, not a rework.
//

import CoreLocation
import Foundation
import MapKit
#if canImport(UIKit)
import UIKit
#endif

/// One maps-app row in the directions chooser.
struct DirectionsProvider: Identifiable {
    /// Stable provider id ("apple", "google").
    let id: String
    /// Display name for the chooser row.
    let name: String
    /// The peer pin's coordinate the route ends at.
    let coordinate: CLLocationCoordinate2D
    /// Deep link for external apps; nil for Apple Maps, which is launched
    /// through MapKit (walking route) instead.
    let url: URL?
}

@available(iOS 17.0, *)
struct DirectionsLauncher {
    /// Injectable `canOpenURL` seam so provider listing is unit-testable
    /// without UIKit.
    protocol SchemeProbe {
        func canOpen(scheme: String) -> Bool
    }

    struct SystemSchemeProbe: SchemeProbe {
        func canOpen(scheme: String) -> Bool {
            guard let url = URL(string: "\(scheme)://") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    /// Google Maps' documented directions URL scheme. Requires an
    /// `LSApplicationQueriesSchemes` entry in Info.plist or `canOpenURL`
    /// always reports it as missing.
    static let googleMapsScheme = "comgooglemaps"

    private let probe: any SchemeProbe

    init(probe: any SchemeProbe = SystemSchemeProbe()) {
        self.probe = probe
    }

    /// Directions providers in chooser order: Apple Maps first, Google Maps
    /// second. Apple Maps is always present; Google Maps only when installed.
    func providers(for coordinate: CLLocationCoordinate2D) -> [DirectionsProvider] {
        var result = [
            DirectionsProvider(
                id: "apple",
                name: String(localized: "Apple Maps"),
                coordinate: coordinate,
                url: nil
            ),
        ]
        if probe.canOpen(scheme: Self.googleMapsScheme) {
            result.append(DirectionsProvider(
                id: "google",
                name: String(localized: "Google Maps"),
                coordinate: coordinate,
                url: Self.googleMapsURL(for: coordinate)
            ))
        }
        return result
    }

    /// Google Maps' documented directions deep link, walking mode.
    static func googleMapsURL(for coordinate: CLLocationCoordinate2D) -> URL {
        URL(string: "comgooglemaps://?daddr=\(coordinate.latitude),\(coordinate.longitude)&directionsmode=walking")!
    }

    /// Launch the chosen provider: Apple Maps through MapKit (walking route
    /// parity with Android), everything else through its deep link.
    func open(_ provider: DirectionsProvider) {
        if provider.id == "apple" {
            let placemark = MKPlacemark(coordinate: provider.coordinate)
            let item = MKMapItem(placemark: placemark)
            item.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking,
            ])
        } else if let url = provider.url {
            UIApplication.shared.open(url)
        }
    }
}
