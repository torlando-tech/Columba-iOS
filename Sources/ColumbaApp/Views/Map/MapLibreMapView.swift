//
//  MapLibreMapView.swift
//  ColumbaApp
//
//  UIViewRepresentable wrapper for MLNMapView with OpenFreeMap tiles.
//

#if os(iOS)
import SwiftUI
import MapLibre

@available(iOS 17.0, *)
struct MapLibreMapView: UIViewRepresentable {
    @Binding var centerOnUser: Bool
    @Binding var metersPerPixel: Double
    var showsUserLocation: Bool

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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(metersPerPixel: $metersPerPixel)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        @Binding var metersPerPixel: Double
        private var didCenterOnFirstLocation = false

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
    }
}
#endif
