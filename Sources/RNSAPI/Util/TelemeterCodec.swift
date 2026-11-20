//  Copyright (c) 2026 Torlando Tech LLC.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  TelemeterCodec.swift
//  RNSAPI
//
//  Sideband-compatible Telemeter codec for LXMF FIELD_TELEMETRY (0x02),
//  ported from the retired torlando-tech/LXMF-swift package
//  (`Message/Telemetry.swift`: `LocationTelemetry` + `TelemetryPacket`) and
//  mirroring Android Columba's `rns-api` `TelemeterCodec.kt`. Pure msgpack
//  over RNSAPI's own `packMsgPack`/`unpackMsgPack` (Util/MsgPack.swift) — no
//  protocol-runtime dependency.
//
//  Wire format (byte-identical to Python Sideband `Telemeter.packed()`,
//  Android's TelemeterCodec and the old LXMFSwift encoder): a msgpack map
//  with ascending uint sensor-ID keys — `{0x01: timestamp, 0x02: [7-element
//  location array]}`, key `0x02` omitted when there is no location. The
//  location array matches Python `struct.pack("!i"/"!I"/"!H", …)`: five
//  4-byte big-endian blobs (lat/lon microdegrees, altitude centimeters,
//  speed cm/s, bearing centi-degrees), one 2-byte blob (accuracy centimeters,
//  capped at 655.35 m) and a plain msgpack int (last-update Unix seconds).
//

import Foundation

public enum TelemeterCodec {
    // SID_TIME / SID_LOCATION sensor IDs (Sideband telemeter.py).
    private static let sidTime: UInt8 = 0x01
    private static let sidLocation: UInt8 = 0x02

    /// Sideband-compatible location telemetry — the 7-element SID_LOCATION
    /// sensor array. Mirror of LXMFSwift's `LocationTelemetry`.
    public struct Location: Equatable, Sendable {
        /// Latitude in degrees.
        public var latitude: Double
        /// Longitude in degrees.
        public var longitude: Double
        /// Altitude in meters.
        public var altitude: Double
        /// Speed in m/s.
        public var speed: Double
        /// Bearing in degrees (0-360).
        public var bearing: Double
        /// Horizontal accuracy in meters.
        public var accuracy: Double
        /// Last update timestamp (Unix seconds).
        public var lastUpdate: Int

        public init(latitude: Double, longitude: Double, altitude: Double,
                    speed: Double, bearing: Double, accuracy: Double, lastUpdate: Int) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.speed = speed
            self.bearing = bearing
            self.accuracy = accuracy
            self.lastUpdate = lastUpdate
        }
    }

    /// A complete telemetry packet (packet timestamp + optional location).
    /// Mirror of LXMFSwift's `TelemetryPacket`.
    public struct Packet: Equatable, Sendable {
        /// Packet timestamp (Unix seconds).
        public var timestamp: Int
        /// Location sensor data (nil if not present).
        public var location: Location?

        public init(timestamp: Int, location: Location?) {
            self.timestamp = timestamp
            self.location = location
        }
    }

    // MARK: - Encoding

    /// Encode a telemetry packet to the msgpack FIELD_TELEMETRY bytes.
    ///
    /// Emits the sensor map with ascending uint keys (1 before 2), matching
    /// Python's dict insertion order — `packMsgPack`'s deterministic uint-key
    /// sort guarantees the ordering, so the output is byte-deterministic.
    public static func pack(_ packet: Packet) -> Data {
        var map: [MessagePackValue: MessagePackValue] = [
            .uint(UInt64(sidTime)): .int(Int64(packet.timestamp)),
        ]
        if let location = packet.location {
            map[.uint(UInt64(sidLocation))] = .array(sensorArray(location))
        }
        return packMsgPack(.map(map))
    }

    /// The 7-element SID_LOCATION sensor array: elements 0-5 are big-endian
    /// struct-packed Data blobs, element 6 a plain msgpack int.
    private static func sensorArray(_ location: Location) -> [MessagePackValue] {
        [
            .binary(packInt32(Int32(location.latitude * 1_000_000))),   // microdegrees
            .binary(packInt32(Int32(location.longitude * 1_000_000))),  // microdegrees
            .binary(packInt32(Int32(location.altitude * 100))),         // centimeters
            .binary(packUInt32(UInt32(max(0, location.speed * 100)))),  // cm/s
            .binary(packInt32(Int32(location.bearing * 100))),          // centi-degrees
            .binary(packUInt16(UInt16(min(65535, max(0, location.accuracy * 100))))), // cm (max 655.35 m)
            .int(Int64(location.lastUpdate)),
        ]
    }

    /// Decode a telemetry packet from FIELD_TELEMETRY msgpack bytes. Returns
    /// `nil` only when the bytes aren't a msgpack map; a present-but-malformed
    /// location array yields a packet with `location == nil` (mirrors
    /// LXMFSwift's decoder).
    public static func unpack(_ data: Data) -> Packet? {
        guard let value = try? unpackMsgPack(data), case .map(let map) = value else { return nil }

        // Timestamp: SID_TIME, int or uint; default to now when absent/other.
        let timestamp = int(from: map[.uint(UInt64(sidTime))] ?? map[.int(Int64(sidTime))])
            ?? Int(Date().timeIntervalSince1970)

        // Location: SID_LOCATION, a 7-element sensor array (else nil).
        var decodedLocation: Location?
        if let locValue = map[.uint(UInt64(sidLocation))] ?? map[.int(Int64(sidLocation))],
           case .array(let array) = locValue {
            decodedLocation = location(fromSensorArray: array)
        }

        return Packet(timestamp: timestamp, location: decodedLocation)
    }

    /// Decode the 7-element SID_LOCATION sensor array; `nil` on any shape or
    /// blob-width mismatch (indices 0-4 are 4-byte blobs, index 5 is 2 bytes,
    /// index 6 an int).
    private static func location(fromSensorArray array: [MessagePackValue]) -> Location? {
        guard array.count >= 7 else { return nil }
        guard case .binary(let latData) = array[0], latData.count == 4,
              case .binary(let lonData) = array[1], lonData.count == 4,
              case .binary(let altData) = array[2], altData.count == 4,
              case .binary(let spdData) = array[3], spdData.count == 4,
              case .binary(let brgData) = array[4], brgData.count == 4,
              case .binary(let accData) = array[5], accData.count == 2 else {
            return nil
        }
        guard let lastUpdate = int(from: array[6]) else { return nil }
        return Location(
            latitude: Double(unpackInt32(latData)) / 1_000_000.0,
            longitude: Double(unpackInt32(lonData)) / 1_000_000.0,
            altitude: Double(unpackInt32(altData)) / 100.0,
            speed: Double(unpackUInt32(spdData)) / 100.0,
            bearing: Double(unpackInt32(brgData)) / 100.0,
            accuracy: Double(unpackUInt16(accData)) / 100.0,
            lastUpdate: lastUpdate
        )
    }

    // MARK: - Value helpers

    private static func int(from value: MessagePackValue?) -> Int? {
        switch value {
        case .int(let i):  return Int(exactly: i)
        case .uint(let u): return Int(exactly: u)
        default:           return nil
        }
    }

    // MARK: - Big-endian binary helpers (match Python struct.pack/unpack)

    private static func packInt32(_ value: Int32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 4)
    }
    private static func packUInt32(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 4)
    }
    private static func packUInt16(_ value: UInt16) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 2)
    }

    private static func unpackInt32(_ data: Data) -> Int32 {
        guard data.count == 4 else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).bigEndian }
    }
    private static func unpackUInt32(_ data: Data) -> UInt32 {
        guard data.count == 4 else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }
    private static func unpackUInt16(_ data: Data) -> UInt16 {
        guard data.count == 2 else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian }
    }
}
