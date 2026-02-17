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

@available(iOS 17.0, *)
struct MapLibreMapView: UIViewRepresentable {
    @Binding var centerOnUser: Bool
    @Binding var metersPerPixel: Double
    var showsUserLocation: Bool
    var peerLocations: [PeerLocation]

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
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
            } else {
                // Add new annotation
                let annotation = PeerPointAnnotation()
                annotation.coordinate = coordinate
                annotation.title = peer.displayName ?? peer.shortHash
                annotation.subtitle = peer.isStale ? "Stale" : nil
                annotation.peerHash = peer.id
                annotation.displayInitial = String((peer.displayName ?? peer.shortHash).prefix(1)).uppercased()
                annotation.isStale = peer.isStale
                mapView.addAnnotation(annotation)
                coordinator.peerAnnotations[peer.id] = annotation
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate {
        @Binding var metersPerPixel: Double
        private var didCenterOnFirstLocation = false

        /// Tracks peer annotations by hash for efficient updates.
        var peerAnnotations: [Data: PeerPointAnnotation] = [:]

        init(metersPerPixel: Binding<Double>) {
            _metersPerPixel = metersPerPixel
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

            // Create marker circle with initial
            let markerColor: UIColor = peerAnnotation.isStale ? .gray : .systemBlue
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
            label.text = peerAnnotation.displayInitial
            label.textAlignment = .center
            label.textColor = .white
            label.font = .systemFont(ofSize: 14, weight: .bold)
            circle.addSubview(label)

            // Replace subviews
            annotationView?.subviews.forEach { $0.removeFromSuperview() }
            annotationView?.addSubview(circle)

            return annotationView
        }
    }
}

// MARK: - Peer Point Annotation

/// Custom annotation class carrying peer metadata.
final class PeerPointAnnotation: MLNPointAnnotation {
    var peerHash: Data = Data()
    var displayInitial: String = "?"
    var isStale: Bool = false
}
#endif
