//
//  RnsTelemetry.swift
//  RNSAPI
//
//  Telemetry / location-sharing facet — iOS analog of Android Columba's
//  `rns-api/RnsTelemetry`. Telemetry is its own interface (not folded into
//  RnsLxmf) precisely because it's a per-backend *capability*: the Swift-native
//  backend implements it; the Python backend declares it unsupported.
//
//  Telemetry payloads cross the seam as Sideband-`Telemeter`-packed `Data`
//  (the caller packs via the shared codec), which the backend places under
//  `LxmfFields.FIELD_TELEMETRY` (0x02). This keeps the seam `Sendable`.
//

import Foundation

public protocol RnsTelemetry: AnyObject, Sendable {

    /// Send a single-shot location telemetry update to a peer. `packed` is the
    /// Sideband-`Telemeter`-packed payload (`FIELD_TELEMETRY` 0x02); `customMeta`
    /// is optional app-meta bytes carried in `FIELD_CUSTOM_META` (0xFD).
    @discardableResult
    func sendLocationTelemetry(destHashHex: String, packed: Data, customMeta: Data?) async throws -> SendOutcome

    /// Send a "stop sharing / cease" signal (`FIELD_CUSTOM_META` `{"cease":true}`).
    @discardableResult
    func sendTelemetryCease(destHashHex: String) async throws -> SendOutcome

    /// Act as a telemetry collector (accept/serve others' telemetry). Android parity.
    @discardableResult
    func setTelemetryCollectorMode(enabled: Bool) async -> Bool

    /// Store the local node's own latest telemetry (for collector responses). Android parity.
    @discardableResult
    func storeOwnTelemetry(packed: Data) async -> Bool

    /// Restrict which requester hashes may pull telemetry. Android parity.
    @discardableResult
    func setTelemetryAllowedRequesters(_ allowedHashesHex: Set<String>) async -> Bool
}
