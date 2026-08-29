//
//  PeerLocationFormattingTests.swift
//  ColumbaAppTests
//
//  Pins the peer contact sheet's pure formatting helpers against the
//  Android Columba behavior they mirror: 22.5-degree compass buckets,
//  initial-bearing math, meter/km distance rounding, and the
//  "Updated …" relative-time thresholds.
//

#if os(iOS)
import CoreLocation
import XCTest
@testable import ColumbaApp

@available(iOS 17.0, *)
final class PeerLocationFormattingTests: XCTestCase {

    // MARK: - Compass buckets (Android bearingToDirection boundaries)

    func test_compass_boundaries_and_buckets() {
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(0), "north")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(22.4), "north")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(22.5), "northeast")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(45), "northeast")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(67.5), "east")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(112.5), "southeast")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(157.5), "south")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(202.5), "southwest")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(247.5), "west")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(292.5), "northwest")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(337.5), "north")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(359.9), "north")
    }

    func test_compass_normalizes_negative_and_oversized_bearings() {
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(-90), "west")
        // 450 normalizes to 90 = due east (the test is about normalization,
        // not a specific quadrant).
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(450), "east")
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(-45), "northwest")
    }

    // MARK: - Initial bearing math (known city pairs)

    func test_bearing_north_along_same_meridian() {
        // Straight up a meridian: due north.
        let from = CLLocation(latitude: 47.0, longitude: -122.0)
        let to = CLLocation(latitude: 48.0, longitude: -122.0)
        XCTAssertEqual(PeerLocationFormatting.initialBearing(from: from, to: to), 0, accuracy: 1e-6)
    }

    func test_bearing_seattle_to_boise_is_southeast() {
        // Seattle (47.61, -122.33) → Boise (43.62, -116.20):
        // both components point down-right, so the initial bearing must
        // land inside the southeast bucket (112.5..157.5).
        let from = CLLocation(latitude: 47.6062, longitude: -122.3321)
        let to = CLLocation(latitude: 43.6150, longitude: -116.2023)
        let bearing = PeerLocationFormatting.initialBearing(from: from, to: to)
        XCTAssertGreaterThan(bearing, 112.5)
        XCTAssertLessThan(bearing, 157.5)
        XCTAssertEqual(PeerLocationFormatting.bearingToCompassDirection(bearing), "southeast")
    }

    // MARK: - Distance + direction formatting

    func test_distance_unknown_when_user_location_is_nil() {
        let text = PeerLocationFormatting.formatDistanceAndDirection(
            userCoordinate: nil,
            peerCoordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        )
        XCTAssertEqual(text, "Location unknown")
    }

    func test_distance_under_one_kilometer_is_whole_meters() {
        // ~450 m due east: 1 degree of longitude at 37.7N ≈ 88.4 km, so
        // 0.005 degrees ≈ 442 m.
        let text = PeerLocationFormatting.formatDistanceAndDirection(
            userCoordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            peerCoordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4144)
        )
        let components = text.split(separator: " ")
        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(components[1], "east")
        let meters = Int(components[0].dropLast()) // strip trailing "m"
        XCTAssertNotNil(meters)
        XCTAssertGreaterThanOrEqual(meters!, 400)
        XCTAssertLessThanOrEqual(meters!, 500)
    }

    func test_distance_over_one_kilometer_is_one_decimal_km() {
        // ~1.2 km due east (0.0136 deg ≈ 1203 m at 37.7N).
        let text = PeerLocationFormatting.formatDistanceAndDirection(
            userCoordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            peerCoordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4058)
        )
        XCTAssertEqual(text, "1.2km east")
    }

    // MARK: - "Updated …" relative time (Android thresholds)

    private func updated(_ secondsAgo: Double) -> String {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return PeerLocationFormatting.formatUpdatedTime(
            now.addingTimeInterval(-secondsAgo),
            now: now
        )
    }

    func test_updated_time_buckets() {
        XCTAssertEqual(updated(0), "Updated just now")
        XCTAssertEqual(updated(9.9), "Updated just now")
        XCTAssertEqual(updated(10), "Updated 10s ago")
        XCTAssertEqual(updated(59), "Updated 59s ago")
        XCTAssertEqual(updated(60), "Updated 1m ago")
        XCTAssertEqual(updated(3599), "Updated 59m ago")
        XCTAssertEqual(updated(3600), "Updated 1h ago")
        XCTAssertEqual(updated(86399), "Updated 23h ago")
        XCTAssertEqual(updated(86400), "Updated 1d ago")
        XCTAssertEqual(updated(3 * 86400), "Updated 3d ago")
    }
}
#endif
