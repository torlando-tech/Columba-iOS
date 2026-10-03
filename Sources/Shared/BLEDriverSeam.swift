//
//  BLEDriverSeam.swift
//  Shared
//
//  The NE↔app marshaling for Model B BLE. The NE runs the Python RNS engine,
//  which loads `IOSBLEInterface.py` → `IOSBLEDriver.py`. The driver calls
//  `columba_ble_*` C-ABI symbols via `ctypes.CDLL(None)`. In the NE those
//  symbols are implemented by `NEBLECABIBridge` (a thin forwarder that sends
//  commands over this seam to the app). The app hosts `SwiftBLEBridge`
//  (the real CoreBluetooth radio, the same singleton the shipping Python
//  path uses).
//
//      NE:  IOSBLEDriver (Python) ──CDLL──▶ NEBLECABIBridge : columba_ble_*
//                                                   │  (App-Group seam)
//      app: SwiftBLEBridge (real CoreBluetooth) ◀── AppGroupBLEServer ─┘
//
//  This file defines the WIRE: a transport-agnostic message enum marshaling
//  the `columba_ble_*` C-ABI command surface (NE→app) + the SwiftBLEBridge
//  callback events (app→NE), plus a compact binary codec.
//
//  Direction is by transport queue, not by type:
//   • Commands  (NE→app)  ride the `bleSeamN2A` queue.
//   • Events    (app→NE)  ride the `bleSeamA2N` queue.
//
//  Value-returning C-ABI calls (`columba_ble_get_peer_role/mtu/rssi`) do NOT
//  cross the seam as round trips: the NE forwarder keeps a small per-peer
//  cache (mtu from `mtuNegotiated`, rssi from `deviceDiscovered`, role
//  derived from who initiated the link) and answers them locally, so the
//  synchronous Python `ctypes` call never blocks on a cross-process hop.
//

import Foundation

// MARK: - Message

/// One message on the BLE driver seam. Commands (NE→app) map 1:1 to the
/// `columba_ble_*` C-ABI op surface that `IOSBLEDriver.py` calls; events
/// (app→NE) mirror `SwiftBLEBridge`'s `BleCallbackSlot` invocations.
public enum BLEDriverSeamMessage: Equatable, Sendable {
    // ── Commands: NE → app (drive SwiftBLEBridge) ──
    case start(serviceUuid: String, rxCharUuid: String, txCharUuid: String, identityCharUuid: String)
    case stop
    case setIdentity(identity: Data)
    case startScanning
    case stopScanning
    case startAdvertising(deviceName: String, identity: Data)
    case stopAdvertising
    case connect(address: String)
    case disconnect(address: String)
    case send(address: String, data: Data)
    case syncExistingConnections
    case requestIdentityResync(address: String)
    case configurePower(address: String, txPowerDbm: Int32)

    // ── Events: app → NE (invoke Python driver callbacks) ──
    case deviceDiscovered(address: String, name: String, rssi: Int16)
    case deviceConnected(address: String, peerIdentity: Data?)
    case deviceDisconnected(address: String)
    case dataReceived(address: String, data: Data)
    case mtuNegotiated(address: String, mtu: UInt16)
    case identityReceived(address: String, identityHex: String)
    case addressChanged(old: String, new: String, identityHash: String)
    case error(severity: String, message: String)

    fileprivate enum Tag: UInt8 {
        case start = 1, stop, setIdentity, startScanning, stopScanning
        case startAdvertising, stopAdvertising, connect, disconnect, send
        case syncExistingConnections, requestIdentityResync, configurePower
        case deviceDiscovered = 64, deviceConnected, deviceDisconnected
        case dataReceived, mtuNegotiated, identityReceived, addressChanged, error
    }

    // MARK: Encode

    public func encode() -> Data {
        var w = SeamWriter()
        switch self {
        case let .start(s, rx, tx, id):
            w.tag(.start); w.str(s); w.str(rx); w.str(tx); w.str(id)
        case .stop:
            w.tag(.stop)
        case let .setIdentity(id):
            w.tag(.setIdentity); w.data(id)
        case .startScanning: w.tag(.startScanning)
        case .stopScanning:  w.tag(.stopScanning)
        case let .startAdvertising(name, id):
            w.tag(.startAdvertising); w.str(name); w.data(id)
        case .stopAdvertising: w.tag(.stopAdvertising)
        case let .connect(addr):
            w.tag(.connect); w.str(addr)
        case let .disconnect(addr):
            w.tag(.disconnect); w.str(addr)
        case let .send(addr, data):
            w.tag(.send); w.str(addr); w.data(data)
        case .syncExistingConnections: w.tag(.syncExistingConnections)
        case let .requestIdentityResync(addr):
            w.tag(.requestIdentityResync); w.str(addr)
        case let .configurePower(addr, p):
            w.tag(.configurePower); w.str(addr); w.i32(p)
        case let .deviceDiscovered(addr, name, rssi):
            w.tag(.deviceDiscovered); w.str(addr); w.str(name); w.i16(rssi)
        case let .deviceConnected(addr, id):
            w.tag(.deviceConnected); w.str(addr); w.optData(id)
        case let .deviceDisconnected(addr):
            w.tag(.deviceDisconnected); w.str(addr)
        case let .dataReceived(addr, data):
            w.tag(.dataReceived); w.str(addr); w.data(data)
        case let .mtuNegotiated(addr, mtu):
            w.tag(.mtuNegotiated); w.str(addr); w.u16(mtu)
        case let .identityReceived(addr, id):
            w.tag(.identityReceived); w.str(addr); w.str(id)
        case let .addressChanged(old, new, id):
            w.tag(.addressChanged); w.str(old); w.str(new); w.str(id)
        case let .error(sev, msg):
            w.tag(.error); w.str(sev); w.str(msg)
        }
        return w.out
    }

    // MARK: Decode

    public init(decoding data: Data) throws {
        var r = SeamReader(data)
        let raw = try r.u8()
        guard let tag = Tag(rawValue: raw) else { throw SeamError.unknownTag(raw) }
        switch tag {
        case .start:
            self = .start(serviceUuid: try r.str(), rxCharUuid: try r.str(), txCharUuid: try r.str(), identityCharUuid: try r.str())
        case .stop: self = .stop
        case .setIdentity: self = .setIdentity(identity: try r.data())
        case .startScanning: self = .startScanning
        case .stopScanning: self = .stopScanning
        case .startAdvertising: self = .startAdvertising(deviceName: try r.str(), identity: try r.data())
        case .stopAdvertising: self = .stopAdvertising
        case .connect: self = .connect(address: try r.str())
        case .disconnect: self = .disconnect(address: try r.str())
        case .send: self = .send(address: try r.str(), data: try r.data())
        case .syncExistingConnections: self = .syncExistingConnections
        case .requestIdentityResync: self = .requestIdentityResync(address: try r.str())
        case .configurePower: self = .configurePower(address: try r.str(), txPowerDbm: try r.i32())
        case .deviceDiscovered: self = .deviceDiscovered(address: try r.str(), name: try r.str(), rssi: try r.i16())
        case .deviceConnected: self = .deviceConnected(address: try r.str(), peerIdentity: try r.optData())
        case .deviceDisconnected: self = .deviceDisconnected(address: try r.str())
        case .dataReceived: self = .dataReceived(address: try r.str(), data: try r.data())
        case .mtuNegotiated: self = .mtuNegotiated(address: try r.str(), mtu: try r.u16())
        case .identityReceived: self = .identityReceived(address: try r.str(), identityHex: try r.str())
        case .addressChanged: self = .addressChanged(old: try r.str(), new: try r.str(), identityHash: try r.str())
        case .error: self = .error(severity: try r.str(), message: try r.str())
        }
        try r.expectEnd()
    }
}

public enum SeamError: Error, Equatable {
    case unknownTag(UInt8)
    case truncated
    case trailingBytes(Int)
    case badUTF8
}

// MARK: - Binary writer / reader (big-endian; UInt16-length-prefixed blobs)

struct SeamWriter {
    var out = Data()
    fileprivate mutating func tag(_ t: BLEDriverSeamMessage.Tag) { out.append(t.rawValue) }
    mutating func u8(_ v: UInt8) { out.append(v) }
    mutating func bool(_ v: Bool) { out.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { out.append(UInt8(v >> 8)); out.append(UInt8(v & 0xFF)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF)); out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF));  out.append(UInt8(v & 0xFF))
    }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    /// UInt16-length-prefixed blob (max 65535).
    mutating func data(_ d: Data) {
        precondition(d.count <= 0xFFFF, "seam blob too large (\(d.count))")
        u16(UInt16(d.count)); out.append(d)
    }
    mutating func str(_ s: String) { data(Data(s.utf8)) }
    mutating func optData(_ d: Data?) { if let d { bool(true); data(d) } else { bool(false) } }
    mutating func optStr(_ s: String?) { if let s { bool(true); str(s) } else { bool(false) } }
}

struct SeamReader {
    private let d: Data
    private var i: Int
    init(_ data: Data) { self.d = data; self.i = data.startIndex }
    mutating func u8() throws -> UInt8 {
        guard i < d.endIndex else { throw SeamError.truncated }
        defer { i += 1 }; return d[i]
    }
    mutating func bool() throws -> Bool { try u8() != 0 }
    mutating func u16() throws -> UInt16 { let h = try u8(), l = try u8(); return UInt16(h) << 8 | UInt16(l) }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u32() throws -> UInt32 {
        let a = try u8(), b = try u8(), c = try u8(), e = try u8()
        return UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(e)
    }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func data() throws -> Data {
        let n = Int(try u16())
        guard d.endIndex - i >= n else { throw SeamError.truncated }
        defer { i += n }; return d.subdata(in: i..<(i + n))
    }
    mutating func str() throws -> String {
        guard let s = String(data: try data(), encoding: .utf8) else { throw SeamError.badUTF8 }
        return s
    }
    mutating func optData() throws -> Data? { try bool() ? try data() : nil }
    mutating func optStr() throws -> String? { try bool() ? try str() : nil }
    func expectEnd() throws { if i != d.endIndex { throw SeamError.trailingBytes(d.endIndex - i) } }
}

// MARK: - Transport abstraction

/// Carries `BLEDriverSeamMessage`s across the App-Group. NE: `send` → the
/// NE→app queue, `inbound` ← the app→NE queue. App: reversed.
public protocol BLESeamTransport: AnyObject, Sendable {
    func send(_ message: BLEDriverSeamMessage)
    /// Decoded messages arriving from the other process.
    var inbound: AsyncStream<BLEDriverSeamMessage> { get }
    /// Begin observing the inbound queue. Call once after construction.
    func start()
    /// Stop observing; finishes the inbound stream.
    func stop()
}

public enum BLESeamError: Error, Sendable {
    case driver(String)
}
