//
//  CeaseTelemetry.swift
//  ColumbaApp
//
//  Builds the Android-compatible "stop sharing" (cease) telemetry payload.
//
//  A cease is NOT a bespoke wire message — it's an ordinary location-telemetry
//  send whose Telemeter body is zeroed and which carries Columba's
//  `FIELD_CUSTOM_META` cease flag. This mirrors Android Columba's
//  `LocationSharingManager.sendCeaseMessage`, which builds a
//  `LocationTelemetry(lat=0, lng=0, acc=0, ts=now, cease=true)` and routes it
//  through the same `sendLocationTelemetry` path as a normal update.
//
//  Why BOTH fields are mandatory: Android's receive path
//  (`PythonEventBridge` / `TelemeterCodec`) bails out unless `FIELD_TELEMETRY`
//  (0x02) is present and Telemeter-decodable — only THEN does it read the
//  `FIELD_CUSTOM_META` (0xFD) cease flag. Sending the meta alone (as iOS used
//  to) is silently ignored by Android.
//
//  Not platform-gated (unlike LocationSharingManager) so the cross-platform
//  test hook in AppServices can build the identical payload.
//

import Foundation
import RNSAPI
import LXMFSwift

enum CeaseTelemetry {
    /// The Android-shaped cease payload:
    /// - `packed`: a zeroed-location Sideband Telemeter blob (`FIELD_TELEMETRY`),
    ///   timestamped now so the receiver's staleness check (cease.ts vs last
    ///   received location) lets the delete through.
    /// - `meta`: msgpack `{"cease": true}` (`FIELD_CUSTOM_META`).
    static func payload() -> (packed: Data, meta: Data) {
        let now = Int(Date().timeIntervalSince1970)
        let zeroed = LXMFSwift.LocationTelemetry(
            latitude: 0,
            longitude: 0,
            altitude: 0,
            speed: 0,
            bearing: 0,
            accuracy: 0,
            lastUpdate: now
        )
        let packet = LXMFSwift.TelemetryPacket(timestamp: now, location: zeroed)
        return (packet.encode(), ColumbaMetaCodec.packCease())
    }
}
