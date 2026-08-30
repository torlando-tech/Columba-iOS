//
//  PeerLocationFormatting.swift
//  ColumbaApp
//
//  Pure formatting helpers for the peer map contact sheet: distance +
//  direction from the user, compass bearing buckets, and relative
//  "Updated …" timestamps. Behavior-matches Android Columba's
//  ContactLocationBottomSheet helpers (22.5-degree compass buckets,
//  <10s "just now" / s / m / h / d time buckets, <1km meters else 1-decimal km).
//

import CoreLocation
import Foundation

enum PeerLocationFormatting {
    /// Map an initial bearing (degrees, 0 = north, clockwise) to one of the
    /// 8 compass words, using Android's 22.5-degree bucket boundaries.
    /// Negative and >360 inputs are normalized first.
    static func bearingToCompassDirection(_ bearing: Double) -> String {
        let normalized = (bearing + 360).truncatingRemainder(dividingBy: 360)
        switch normalized {
        case ..<22.5, 337.5...:
            return String(localized: "north")
        case ..<67.5:
            return String(localized: "northeast")
        case ..<112.5:
            return String(localized: "east")
        case ..<157.5:
            return String(localized: "southeast")
        case ..<202.5:
            return String(localized: "south")
        case ..<247.5:
            return String(localized: "southwest")
        case ..<292.5:
            return String(localized: "west")
        default:
            return String(localized: "northwest")
        }
    }

    /// Initial great-circle bearing from `from` to `to` in degrees (0-360).
    /// Same quantity Android's `Location.distanceBetween` reports in its
    /// results array, so the two platforms agree on the compass word.
    static func initialBearing(from: CLLocation, to: CLLocation) -> Double {
        let phi1 = from.coordinate.latitude * .pi / 180
        let phi2 = to.coordinate.latitude * .pi / 180
        let deltaLambda = (to.coordinate.longitude - from.coordinate.longitude) * .pi / 180
        let y = sin(deltaLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda)
        let theta = atan2(y, x) * 180 / .pi
        return (theta + 360).truncatingRemainder(dividingBy: 360)
    }

    /// "450m southeast" / "1.2km northwest", or "Location unknown" when the
    /// user's own location is unavailable. Matches Android's
    /// `formatDistanceAndDirection` (truncated meters below 1km, one decimal
    /// place in km above).
    static func formatDistanceAndDirection(
        userCoordinate: CLLocationCoordinate2D?,
        peerCoordinate: CLLocationCoordinate2D
    ) -> String {
        guard let userCoordinate else {
            return String(localized: "Location unknown")
        }
        let from = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        let to = CLLocation(latitude: peerCoordinate.latitude, longitude: peerCoordinate.longitude)
        let meters = from.distance(from: to)
        let bearing = initialBearing(from: from, to: to)
        let distanceText = meters < 1000
            ? "\(Int(meters))m"
            : String(format: "%.1fkm", meters / 1000)
        return "\(distanceText) \(bearingToCompassDirection(bearing))"
    }

    /// "Updated just now" / "Updated 30s ago" / "Updated 5m ago" /
    /// "Updated 2h ago" / "Updated 3d ago" with Android's thresholds
    /// (<10s, <1m, <1h, <1d). `now` is injectable for tests.
    static func formatUpdatedTime(_ lastUpdate: Date, now: Date = Date()) -> String {
        let diffSeconds = now.timeIntervalSince(lastUpdate)
        if diffSeconds < 10 {
            return String(localized: "Updated just now")
        } else if diffSeconds < 60 {
            return String(localized: "Updated \(Int(diffSeconds))s ago")
        } else if diffSeconds < 3600 {
            return String(localized: "Updated \(Int(diffSeconds / 60))m ago")
        } else if diffSeconds < 86400 {
            return String(localized: "Updated \(Int(diffSeconds / 3600))h ago")
        } else {
            return String(localized: "Updated \(Int(diffSeconds / 86400))d ago")
        }
    }
}
