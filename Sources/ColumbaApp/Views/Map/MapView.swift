//
//  MapView.swift
//  ColumbaApp
//
//  Map tab with full-screen MapLibre map, scale bar, and location button.
//

import SwiftUI
#if os(iOS)
import CoreLocation
#endif

@available(iOS 17.0, macOS 14.0, *)
struct MapView: View {
    #if os(iOS)
    @State private var centerOnUser = false
    @State private var metersPerPixel: Double = 1000
    @State private var locationAuthorized = false
    @State private var locationManager = CLLocationManager()
    @State private var authorizationDelegate: LocationAuthorizationDelegate?

    var body: some View {
        ZStack {
            MapLibreMapView(
                centerOnUser: $centerOnUser,
                metersPerPixel: $metersPerPixel,
                showsUserLocation: locationAuthorized
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    ScaleBarView(metersPerPixel: metersPerPixel)
                        .padding(.leading, 16)
                        .padding(.top, 60)
                    Spacer()
                }

                Spacer()

                HStack {
                    Spacer()
                    Button {
                        requestLocationAndCenter()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                }
                .padding(.bottom, 4)
            }
        }
        .onAppear {
            checkLocationAuthorization()
        }
    }

    private func checkLocationAuthorization() {
        let status = locationManager.authorizationStatus
        locationAuthorized = (status == .authorizedWhenInUse || status == .authorizedAlways)

        if authorizationDelegate == nil {
            let delegate = LocationAuthorizationDelegate { authorized in
                locationAuthorized = authorized
            }
            authorizationDelegate = delegate
            locationManager.delegate = delegate
        }
    }

    private func requestLocationAndCenter() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            centerOnUser = true
        }
    }

    #else
    // macOS fallback
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundPrimary
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.accentColor)
                    Text("Map")
                        .font(.screenTitle)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Map view is available on iOS")
                        .font(.bodyText)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding()
            }
            .navigationTitle("Map")
        }
    }
    #endif
}

// MARK: - Scale Bar

@available(iOS 17.0, macOS 14.0, *)
private struct ScaleBarView: View {
    let metersPerPixel: Double

    var body: some View {
        let (label, barWidth) = scaleBarParams()
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
            HStack(spacing: 0) {
                Rectangle()
                    .frame(width: 2, height: 6)
                Rectangle()
                    .frame(width: barWidth, height: 2)
                Rectangle()
                    .frame(width: 2, height: 6)
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func scaleBarParams() -> (String, CGFloat) {
        let niceValues: [(Double, String)] = [
            (5, "5 m"), (10, "10 m"), (20, "20 m"), (50, "50 m"),
            (100, "100 m"), (200, "200 m"), (500, "500 m"),
            (1_000, "1 km"), (2_000, "2 km"), (5_000, "5 km"),
            (10_000, "10 km"), (20_000, "20 km"), (50_000, "50 km"),
            (100_000, "100 km"), (200_000, "200 km"), (500_000, "500 km"),
            (1_000_000, "1000 km"),
        ]

        let minWidth: CGFloat = 60
        let maxWidth: CGFloat = 140

        for (meters, label) in niceValues {
            let width = CGFloat(meters / metersPerPixel)
            if width >= minWidth && width <= maxWidth {
                return (label, width)
            }
        }

        // Fallback: pick closest that fits
        for (meters, label) in niceValues.reversed() {
            let width = CGFloat(meters / metersPerPixel)
            if width >= minWidth {
                return (label, min(width, maxWidth))
            }
        }

        let (meters, label) = niceValues.first!
        return (label, max(CGFloat(meters / metersPerPixel), minWidth))
    }
}

// MARK: - Location Authorization Delegate

#if os(iOS)
private final class LocationAuthorizationDelegate: NSObject, CLLocationManagerDelegate {
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        onChange(status == .authorizedWhenInUse || status == .authorizedAlways)
    }
}
#endif

// MARK: - Preview

#if DEBUG
@available(iOS 17.0, macOS 14.0, *)
#Preview {
    MapView()
        .preferredColorScheme(.dark)
}
#endif
