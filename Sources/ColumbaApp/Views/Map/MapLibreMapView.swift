//
//  MapLibreMapView.swift
//  ColumbaApp
//
//  UIViewRepresentable wrapper for MLNMapView with OpenFreeMap tiles.
//  Displays user location and peer location markers from telemetry.
//

#if os(iOS)
import SwiftUI
import RNSAPI
import MapLibre

/// Returns the OpenFreeMap style URL for the active color scheme.
/// MLNOfflineStorage caches the style JSON + tiles during region download,
/// so loading this URL offline serves everything from the local cache —
/// but cached regions are pinned to one style at download time, so the
/// dark style assets are not served offline if a region was downloaded
/// while light was active. TODO(#59 follow-up): cache both style packs.
func mapStyleURL(forDarkMode dark: Bool) -> URL {
    URL(string: dark
        ? "https://tiles.openfreemap.org/styles/dark"
        : "https://tiles.openfreemap.org/styles/liberty")!
}

@available(iOS 17.0, *)
struct MapLibreMapView: UIViewRepresentable {
    @Binding var centerOnUser: Bool
    @Binding var metersPerPixel: Double
    /// The peer hash whose pin is currently selected (drives the contact
    /// sheet in MapView and the map's selection highlight).
    @Binding var selectedPeerHash: Data?
    var showsUserLocation: Bool
    var peerLocations: [PeerLocation]
    var httpEnabled: Bool
    var isDark: Bool
    /// Called on the main thread when the user taps a peer pin. MapView
    /// sets `selectedPeerHash`, which both presents the contact sheet and
    /// re-asserts the selection highlight from `updateUIView`.
    var onPeerTapped: ((Data) -> Void)?
    /// Mirrors `MLNMapView.userLocation?.coordinate` up to SwiftUI so the
    /// contact sheet can compute distance/direction before the map has
    /// rendered a fix.
    var onUserLocationChanged: ((CLLocationCoordinate2D?) -> Void)?

    func makeUIView(context: Context) -> MLNMapView {
        // Set up network delegate to block HTTP when toggle is off.
        // MLNOfflineStorage serves cached tiles before this delegate is called,
        // so only uncached tile requests are blocked.
        context.coordinator.httpEnabled = httpEnabled
        MLNNetworkConfiguration.sharedManager.delegate = context.coordinator

        let initialStyleURL = mapStyleURL(forDarkMode: isDark)
        context.coordinator.lastStyleURL = initialStyleURL
        let mapView = MLNMapView(frame: .zero, styleURL: initialStyleURL)
        // Stable UI-automation landmark while the style and visible tiles load.
        // The coordinator promotes this to `map_canvas_ready` only after
        // MapLibre reports that all currently requested tiles and transitions
        // are complete.
        mapView.accessibilityIdentifier = "screen_map"
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
        context.coordinator.onPeerTapped = onPeerTapped
        context.coordinator.onUserLocationChanged = onUserLocationChanged

        // Swap style URL when color scheme changes; lastStyleURL avoids
        // a no-op assignment (which would still trigger a reload) on every
        // peer-location tick.
        let desiredStyleURL = mapStyleURL(forDarkMode: isDark)
        if context.coordinator.lastStyleURL != desiredStyleURL {
            context.coordinator.lastStyleURL = desiredStyleURL
            mapView.styleURL = desiredStyleURL
        }

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
        // Keep the map's selection coherent across peer churn: re-assert the
        // highlight when a newer telemetry tick rebuilt the selected peer's
        // annotation, and clear it when the selection was lifted (sheet
        // dismissed, peer removed, stale pin vanished).
        updateSelection(on: mapView, coordinator: context.coordinator)
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

    /// Keep MapLibre's built-in selection highlight in sync with the
    /// SwiftUI-owned `selectedPeerHash`. Selection is keyed on the peer hash
    /// (the source of truth), never on the annotation object: MapLibre
    /// reuses and rebuilds annotation views on every telemetry tick, so an
    /// object-identity-based selection can go stale. Also drops the highlight
    /// when the selection is cleared (sheet dismissed, peer removed, stale
    /// pin vanished) so a dimmed ghost pin can't linger.
    private func updateSelection(on mapView: MLNMapView, coordinator: Coordinator) {
        if let selectedHash = selectedPeerHash,
           let annotation = coordinator.peerAnnotations[selectedHash] {
            // No-op when the same annotation is already selected: a newer
            // telemetry tick for the selected peer re-runs this path and we
            // must not restart the selection animation on every update.
            if annotation !== coordinator.lastSelectedAnnotation {
                mapView.selectAnnotation(annotation, animated: true, completionHandler: nil)
                coordinator.lastSelectedAnnotation = annotation
            }
        } else if let last = coordinator.lastSelectedAnnotation {
            if mapView.selectedAnnotations.contains(where: { $0 === last }) {
                mapView.deselectAnnotation(last, animated: true)
            }
            coordinator.lastSelectedAnnotation = nil
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate, MLNNetworkConfigurationDelegate {
        @Binding var metersPerPixel: Double
        private var didCenterOnFirstLocation = false

        /// Whether HTTP tile fetching is allowed.
        var httpEnabled = true

        /// Last style URL applied to the underlying MLNMapView; used to skip
        /// no-op assignments on the frequent SwiftUI updates that don't change
        /// the color scheme.
        var lastStyleURL: URL?

        /// Tracks peer annotations by hash for efficient updates.
        var peerAnnotations: [Data: PeerPointAnnotation] = [:]

        /// Fired when the user taps a peer pin (main thread).
        var onPeerTapped: ((Data) -> Void)?

        /// Mirrors the map's user-location coordinate up to SwiftUI.
        var onUserLocationChanged: ((CLLocationCoordinate2D?) -> Void)?

        /// Last annotation the representable selected programmatically.
        /// Guards against re-selecting the same object every tick (which
        /// would restart the selection animation on every peer update).
        var lastSelectedAnnotation: MLNAnnotation?

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

        func mapViewWillStartLoadingMap(_ mapView: MLNMapView) {
            mapView.accessibilityIdentifier = "screen_map"
        }

        func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
            // MLNMapViewDelegate defines idle as no active camera transition,
            // all currently requested tiles loaded, and all fade/transition
            // animations completed. This is the screenshotter's real network
            // and render readiness signal; an animation timeout is not.
            mapView.accessibilityIdentifier = "map_canvas_ready"
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            let coordinate = userLocation?.coordinate
            let valid = coordinate.flatMap { CLLocationCoordinate2DIsValid($0) ? $0 : nil }
            onUserLocationChanged?(valid)
            guard !didCenterOnFirstLocation, let coordinate,
                  CLLocationCoordinate2DIsValid(coordinate) else { return }
            didCenterOnFirstLocation = true
            mapView.setCenter(coordinate, zoomLevel: 13, animated: true)
        }

        // MARK: - Annotation selection (peer pin taps)

        /// MapLibre annotation views are tappable by default (`enabled` is
        /// YES); this reports the tapped peer up to SwiftUI, which presents
        /// the contact sheet and re-asserts the selection highlight.
        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let peerAnnotation = annotation as? PeerPointAnnotation else { return }
            onPeerTapped?(peerAnnotation.peerHash)
        }

        func mapView(_ mapView: MLNMapView, didDeselect annotation: MLNAnnotation) {
            // MapLibre deselects the previous pin when a new one is tapped;
            // the SwiftUI binding (the source of truth) already points at the
            // newly selected peer, so there is nothing to mirror back. This
            // hook exists so a future "tap empty map to close the sheet"
            // behavior has a natural place to clear `selectedPeerHash`.
        }

        /// Suppress the built-in MapLibre callout bubble: the contact sheet
        /// (driven by `onPeerTapped`) is the only selection UI, so a
        /// redundant title/subtitle callout would flash on every tap.
        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            return annotation is PeerPointAnnotation ? false : true
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
            // XCUITest/Maestro addressability: the pin itself is a real UIView
            // (unlike the GL-drawn map), so the interop suite can tap it
            // directly instead of guessing where the marker landed.
            // `accessibilityElement = true` + a label are required for the
            // view to be reachable at all - an identifier alone is ignored by
            // the accessibility tree (the view is reused, so set these on
            // every refresh, not just first creation).
            annotationView?.accessibilityIdentifier = "peer_pin_\(peerAnnotation.peerHash.toHex())"
            annotationView?.isAccessibilityElement = true
            annotationView?.accessibilityLabel = peerAnnotation.title ?? "Peer location"
            annotationView?.accessibilityTraits = .button

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
