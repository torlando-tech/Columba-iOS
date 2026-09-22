//
//  Types.swift
//  ColumbaNode
//
//  The common type system (contract 2, IDL scalars). Distinct wrapper types so the
//  various IDs / hashes / counters are never interchangeable raw strings at the
//  API boundary (IDL: "Identifiers named ID are distinct UUID wrappers, never
//  interchangeable strings").
//
//  All are Sendable value types. Hex scalars are stored lowercase and validated.
//  Counters (Revision/Sequence/LocalSequence) are UInt64, carried as decimal
//  strings on the JSON wire (no leading zeros, no "+").
//

import Foundation

// MARK: - Distinct UUID wrappers

/// Local UUID assigned to one private-key identity; never UI selection.
public struct IdentityID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
/// One immutable request to act. The stable command key is (storeEpoch, commandID).
public struct CommandID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
/// A message. Outbound MessageID == initial CommandID (distinct types).
public struct MessageID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
/// One accepted unit of node work.
public struct OperationID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
public struct InterfaceID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
public struct CallID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
/// An immutable managed payload file.
public struct BlobID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
/// UUID changed on store replacement/reset/restore, not normal migration.
public struct StoreEpoch: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
/// Fresh UUID each NE service runtime; ephemeral handles scoped to it.
public struct BootID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
public struct LeaseID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
public struct ChannelID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
public struct HostID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
public struct ActionID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }
public struct RequestID: Hashable, Sendable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw }; public init?(wire: String) { guard let u = UUID(uuidString: wire.lowercased()) else { return nil }; self.raw = u }; public var wire: String { raw.uuidString.lowercased() } }

// MARK: - Hex scalars

/// A fixed-size lowercase hex blob. `ByteCount` fixes width; values are validated.
public struct HexBlob: Hashable, Sendable, CustomStringConvertible {
    public let bytes: Data
    public init(_ bytes: Data) { self.bytes = bytes }
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public var description: String { hex }
    public init?(hex: String, byteCount: Int) {
        let h = hex.lowercased()
        guard h.count == byteCount * 2 else { return nil }
        var out = Data(capacity: byteCount)
        var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            guard let byte = UInt8(h[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        self.bytes = out
    }
}

public struct IdentityHash: Hashable, Sendable {          // 16 bytes, 32 hex
    public let raw: HexBlob
    public init(_ raw: HexBlob) { self.raw = raw }
    public init?(hex: String) { guard let h = HexBlob(hex: hex, byteCount: 16) else { return nil }; self.raw = h }
    public var hex: String { raw.hex }
}
public struct DestinationHash: Hashable, Sendable {        // 16 bytes, 32 hex
    public let raw: HexBlob
    public init(_ raw: HexBlob) { self.raw = raw }
    public init?(hex: String) { guard let h = HexBlob(hex: hex, byteCount: 16) else { return nil }; self.raw = h }
    public var hex: String { raw.hex }
}
public struct MessageHash: Hashable, Sendable {            // 32 bytes, 64 hex
    public let raw: HexBlob
    public init(_ raw: HexBlob) { self.raw = raw }
    public init?(hex: String) { guard let h = HexBlob(hex: hex, byteCount: 32) else { return nil }; self.raw = h }
    public var hex: String { raw.hex }
}
public struct Digest: Hashable, Sendable {                 // 32 bytes, 64 hex
    public let raw: HexBlob
    public init(_ raw: HexBlob) { self.raw = raw }
    public init?(hex: String) { guard let h = HexBlob(hex: hex, byteCount: 32) else { return nil }; self.raw = h }
    public var hex: String { raw.hex }
    public init(data: Data) {
        guard data.count == 32 else { fatalError("Digest must be 32 bytes") }
        self.raw = HexBlob(data)
    }
}
public struct PublicIdentityKey: Hashable, Sendable {      // 64 bytes, 128 hex
    public let raw: HexBlob
    public init(_ raw: HexBlob) { self.raw = raw }
    public init?(hex: String) { guard let h = HexBlob(hex: hex, byteCount: 64) else { return nil }; self.raw = h }
    public var hex: String { raw.hex }
}

// MARK: - Counters + time + cursor

/// Unsigned 64-bit counter (Revision / Sequence / LocalSequence share this
/// representation; the IDL keeps them as distinct names for API clarity).
public struct Counter: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
    /// Wire form: decimal, no leading zeros, no "+".
    public var wire: String { String(value) }
    public init?(wire: String) {
        guard let v = UInt64(wire), !wire.hasPrefix("+"), !wire.hasPrefix("-") else { return nil }
        // No leading zeros except the single "0".
        if wire.count > 1 && wire.hasPrefix("0") { return nil }
        self.value = v
    }
    public static func < (l: Counter, r: Counter) -> Bool { l.value < r.value }
    public var description: String { wire }
}

/// UTC epoch milliseconds.
public struct Instant: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let epochMillis: Int64
    public init(_ epochMillis: Int64) { self.epochMillis = epochMillis }
    public init(date: Date) { self.epochMillis = Int64(date.timeIntervalSince1970 * 1000) }
    public var date: Date { Date(timeIntervalSince1970: Double(epochMillis) / 1000.0) }
    public static func < (l: Instant, r: Instant) -> Bool { l.epochMillis < r.epochMillis }
    public var description: String { String(epochMillis) }
}

/// Nonnegative integer (Duration ms / Bytes / Count).
public struct NonNegative: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public var wire: String { String(value) }
    public init?(wire: String) {
        guard let v = UInt64(wire) else { return nil }
        self.value = v
    }
    public static func < (l: NonNegative, r: NonNegative) -> Bool { l.value < r.value }
    public var description: String { wire }
}

/// `{storeEpoch, sequence}` — commit order, not wall-clock.
public struct Cursor: Hashable, Sendable {
    public let storeEpoch: StoreEpoch
    public let sequence: Counter
    public init(storeEpoch: StoreEpoch, sequence: Counter) {
        self.storeEpoch = storeEpoch
        self.sequence = sequence
    }
}

/// Feature capabilities (IDL `enum Feature`). Base service/store/hello/
/// identity-create/status are mandatory, not listed features.
public enum Feature: String, CaseIterable, Sendable {
    case durableMessaging
    case attachments
    case replies
    case reactions
    case reactionRemoval
    case extensionFields
    case identitySwitching
    case multipleEnabledIdentities
    case propagation
    case telemetry
    case telemetryCollector
    case nomadnetPages
    case nomadnetMedia
    case voiceSignaling
    case voiceForegroundMedia
    case voiceBackgroundMedia
    case tcpClient
    case tcpServer
    case udp
    case lanDiscovery
    case blePeer
    case rnode
    case hostRadio
    case transportRouting
    case transportBlackhole
    case diagnostics
    case protocolProbe
    case identityImport
    case identityExport
}

/// Availability of a feature/capability (IDL `enum Availability`).
public enum Availability: String, CaseIterable, Sendable {
    case available
    case disabled
    case identityDisabled
    case keyLocked
    case noInterface
    case requiresAppHost
    case resourceConstrained
    case recovering
}
