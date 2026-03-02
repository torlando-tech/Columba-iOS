//
//  MapLibreMapView.swift
//  ColumbaApp
//
//  UIViewRepresentable wrapper for MLNMapView with OpenFreeMap tiles.
//  Displays user location and peer location markers from telemetry.
//

#if os(iOS)
import SwiftUI
import MapLibre
import LXMFSwift

@available(iOS 17.0, *)
struct MapLibreMapView: UIViewRepresentable {
    @Binding var centerOnUser: Bool
    @Binding var metersPerPixel: Double
    var showsUserLocation: Bool
    var peerLocations: [PeerLocation]
    var httpEnabled: Bool

    /// Style URL from OpenFreeMap — used for both online and offline modes.
    /// MLNOfflineStorage caches the style JSON + tiles during region download,
    /// so loading this URL offline serves everything from the local cache.
    private static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    func makeUIView(context: Context) -> MLNMapView {
        // Set up network delegate to block HTTP when toggle is off.
        // MLNOfflineStorage serves cached tiles before this delegate is called,
        // so only uncached tile requests are blocked.
        context.coordinator.httpEnabled = httpEnabled
        MLNNetworkConfiguration.sharedManager.delegate = context.coordinator

        let mapView = MLNMapView(frame: .zero, styleURL: Self.styleURL)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.showsUserLocation = showsUserLocation
        mapView.delegate = context.coordinator

        // Start zoomed out; will animate to user once location acquired
        mapView.setCenter(CLLocationCoordinate2D(latitude: 20, longitude: 0), zoomLevel: 1.5, animated: false)

        // Attribution in bottom-left
        mapView.attributionButtonPosition = .bottomLeft
        mapView.attributionButtonMargins = CGPoint(x: 8, y: 8)
        mapView.logoView.isHidden = true

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        mapView.showsUserLocation = showsUserLocation

        // Update network blocking state when HTTP toggle changes
        context.coordinator.httpEnabled = httpEnabled

        if centerOnUser {
            DispatchQueue.main.async {
                centerOnUser = false
            }
            if let location = mapView.userLocation?.coordinate,
               CLLocationCoordinate2DIsValid(location) {
                mapView.setCenter(location, zoomLevel: 15, animated: true)
            }
        }

        // Update peer annotations
        updatePeerAnnotations(on: mapView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(metersPerPixel: $metersPerPixel)
    }

    // MARK: - Peer Annotation Management

    private func updatePeerAnnotations(on mapView: MLNMapView, coordinator: Coordinator) {
        let currentPeerIds = Set(peerLocations.map { $0.id })
        let existingAnnotations = coordinator.peerAnnotations

        // Remove annotations for peers no longer present
        for (peerId, annotation) in existingAnnotations {
            if !currentPeerIds.contains(peerId) {
                mapView.removeAnnotation(annotation)
                coordinator.peerAnnotations.removeValue(forKey: peerId)
            }
        }

        // Add or update annotations
        for peer in peerLocations {
            let coordinate = CLLocationCoordinate2D(latitude: peer.latitude, longitude: peer.longitude)

            if let existing = coordinator.peerAnnotations[peer.id] {
                // Update position with animation
                UIView.animate(withDuration: 0.5) {
                    existing.coordinate = coordinate
                }
                existing.title = peer.displayName ?? peer.shortHash
                existing.subtitle = peer.isStale ? "Stale" : nil
                existing.isStale = peer.isStale
                if let icon = peer.iconAppearance {
                    existing.iconName = icon.iconName
                    existing.iconForegroundColor = icon.foregroundColor
                    existing.iconBackgroundColor = icon.backgroundColor
                }
            } else {
                // Add new annotation
                let annotation = PeerPointAnnotation()
                annotation.coordinate = coordinate
                annotation.title = peer.displayName ?? peer.shortHash
                annotation.subtitle = peer.isStale ? "Stale" : nil
                annotation.peerHash = peer.id
                annotation.displayInitial = String((peer.displayName ?? peer.shortHash).prefix(1)).uppercased()
                annotation.isStale = peer.isStale
                if let icon = peer.iconAppearance {
                    annotation.iconName = icon.iconName
                    annotation.iconForegroundColor = icon.foregroundColor
                    annotation.iconBackgroundColor = icon.backgroundColor
                }
                mapView.addAnnotation(annotation)
                coordinator.peerAnnotations[peer.id] = annotation
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate, MLNNetworkConfigurationDelegate {
        @Binding var metersPerPixel: Double
        private var didCenterOnFirstLocation = false

        /// Whether HTTP tile fetching is allowed.
        var httpEnabled = true

        /// Tracks peer annotations by hash for efficient updates.
        var peerAnnotations: [Data: PeerPointAnnotation] = [:]

        init(metersPerPixel: Binding<Double>) {
            _metersPerPixel = metersPerPixel
        }

        // MARK: - MLNNetworkConfigurationDelegate

        /// Block network requests when HTTP maps are disabled.
        /// MLNOfflineStorage serves cached tiles before this is called,
        /// so only truly uncached tile requests reach here.
        func willSend(_ request: NSMutableURLRequest) -> NSMutableURLRequest {
            if !httpEnabled {
                request.timeoutInterval = 0.001
            }
            return request
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            metersPerPixel = mapView.metersPerPoint(atLatitude: mapView.centerCoordinate.latitude)
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            guard !didCenterOnFirstLocation,
                  let coordinate = userLocation?.coordinate,
                  CLLocationCoordinate2DIsValid(coordinate) else { return }
            didCenterOnFirstLocation = true
            mapView.setCenter(coordinate, zoomLevel: 13, animated: true)
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let peerAnnotation = annotation as? PeerPointAnnotation else {
                return nil
            }

            let reuseId = "peer-marker"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId)

            if annotationView == nil {
                annotationView = MLNAnnotationView(annotation: annotation, reuseIdentifier: reuseId)
                annotationView?.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            }

            // Create marker circle with MDI icon or initial fallback
            let markerColor: UIColor
            if let bgHex = peerAnnotation.iconBackgroundColor {
                markerColor = peerAnnotation.isStale ? .gray : UIColor(hexRGB: bgHex)
            } else {
                markerColor = peerAnnotation.isStale ? .gray : .systemBlue
            }

            let circle = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
            circle.backgroundColor = markerColor
            circle.layer.cornerRadius = 16
            circle.layer.borderColor = UIColor.white.cgColor
            circle.layer.borderWidth = 2
            circle.layer.shadowColor = UIColor.black.cgColor
            circle.layer.shadowOffset = CGSize(width: 0, height: 2)
            circle.layer.shadowRadius = 3
            circle.layer.shadowOpacity = 0.3

            let label = UILabel(frame: circle.bounds)
            label.textAlignment = .center

            if let iconName = peerAnnotation.iconName,
               let char = MaterialDesignIcons.character(for: iconName),
               let mdiFont = UIFont(name: MaterialDesignIcons.fontName, size: 18) {
                label.text = String(char)
                label.font = mdiFont
                if let fgHex = peerAnnotation.iconForegroundColor {
                    label.textColor = UIColor(hexRGB: fgHex)
                } else {
                    label.textColor = .white
                }
            } else {
                label.text = peerAnnotation.displayInitial
                label.font = .systemFont(ofSize: 14, weight: .bold)
                label.textColor = .white
            }
            circle.addSubview(label)

            // Replace subviews
            annotationView?.subviews.forEach { $0.removeFromSuperview() }
            annotationView?.addSubview(circle)

            return annotationView
        }
    }
}

// MARK: - Peer Point Annotation

// MARK: - UIColor hex extension

private extension UIColor {
    convenience init(hexRGB hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

/// Custom annotation class carrying peer metadata.
final class PeerPointAnnotation: MLNPointAnnotation {
    var peerHash: Data = Data()
    var displayInitial: String = "?"
    var isStale: Bool = false
    var iconName: String?
    var iconForegroundColor: String?
    var iconBackgroundColor: String?
}
#endif
