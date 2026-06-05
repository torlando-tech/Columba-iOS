//
//  BLEDriverSeam.swift
//  Shared
//
//  The NE↔app marshaling for Model B BLE. reticulum-swift already ships the
//  proven Swift BLE mesh stack (`BLEInterface`, `BLEPeerInterface`,
//  `CoreBluetoothBLEDriver`, `BLEDriver`/`BLEPeerConnection`, fragmentation). The
//  ONLY missing piece for Model B is the cross-process seam, because RNS runs in
//  the Network Extension but CoreBluetooth must run in the app:
//
//      NE:  ReticulumSwift.BLEInterface  ──uses──▶  AppGroupBLEDriver : BLEDriver
//                                                   AppGroupBLEPeerConnection : BLEPeerConnection
//                                                            │  (App-Group)
//      app: CoreBluetoothBLEDriver (real) ◀── App-Group server ─┘
//
//  This file defines the WIRE between them: a transport-agnostic message enum
//  marshaling the `BLEDriver` + `BLEPeerConnection` protocol surface, plus a
//  compact binary codec. Direction is by transport, not by type:
//   • Commands  (NE→app)  ride the `e2a` queue, tag `.bleControl`.
//   • Events    (app→NE)  ride the `a2e` queue, tag `.bleControl`.
//   • Fragments (both)    ride the queues tag `.bleMesh`, body `[addr][fragment]`
//     — high-rate, so `sendFragment`/`receivedFragment` are ALSO modeled here for
//     completeness but the transport routes them as raw frames, not via this codec.
//
//  Methods that return a value across the process boundary (`connect`,
//  `readIdentity`, `readRemoteRssi`, the local-state query) carry a `reqId` so the
//  NE can resume the awaiting continuation when the matching `*Result` arrives.
//  Per locked decision #1, the synchronous-decision callbacks (`should_connect`,
//  duplicate-identity) live entirely app-side and never cross this seam.
//

import Foundation

// MARK: - Message

/// One message on the BLE driver seam. `reqId` correlates a request with its
/// `*Result` reply for the value-returning driver/connection methods.
public enum BLEDriverSeamMessage: Equatable, Sendable {
    // ── Commands: NE → app (drive `CoreBluetoothBLEDriver`) ──
    case startAdvertising
    case stopAdvertising
    case startScanning
    case stopScanning
    case connect(reqId: UInt32, address: String)
    case disconnect(address: String)
    case shutdown
    case queryLocalState(reqId: UInt32)             // localAddress + isRunning
    // per-connection commands (address identifies the BLEPeerConnection)
    case sendFragment(address: String, data: Data)  // data-path (see header)
    case readIdentity(reqId: UInt32, address: String)
    case writeIdentity(address: String, identity: Data)
    case readRemoteRssi(reqId: UInt32, address: String)
    case closeConnection(address: String)

    // ── Events / results: app → NE (feed `BLEInterface`'s streams) ──
    case discovered(address: String, rssi: Int16, identity: Data?)
    case incomingConnection(address: String, mtu: UInt16, identity: Data?)
    case connectionLost(address: String)
    case receivedFragment(address: String, data: Data)  // data-path (see header)
    case connectResult(reqId: UInt32, address: String, mtu: UInt16, identity: Data?, error: String?)
    case readIdentityResult(reqId: UInt32, identity: Data?, error: String?)
    case readRemoteRssiResult(reqId: UInt32, rssi: Int16, error: String?)
    case queryLocalStateResult(reqId: UInt32, localAddress: String?, isRunning: Bool)

    fileprivate enum Tag: UInt8 {
        case startAdvertising = 1, stopAdvertising, startScanning, stopScanning
        case connect, disconnect, shutdown, queryLocalState
        case sendFragment, readIdentity, writeIdentity, readRemoteRssi, closeConnection
        case discovered = 64, incomingConnection, connectionLost, receivedFragment
        case connectResult, readIdentityResult, readRemoteRssiResult, queryLocalStateResult
    }

    // MARK: Encode

    public func encode() -> Data {
        var w = SeamWriter()
        switch self {
        case .startAdvertising: w.tag(.startAdvertising)
        case .stopAdvertising:  w.tag(.stopAdvertising)
        case .startScanning:    w.tag(.startScanning)
        case .stopScanning:     w.tag(.stopScanning)
        case .shutdown:         w.tag(.shutdown)
        case let .connect(reqId, address):
            w.tag(.connect); w.u32(reqId); w.str(address)
        case let .disconnect(address):
            w.tag(.disconnect); w.str(address)
        case let .queryLocalState(reqId):
            w.tag(.queryLocalState); w.u32(reqId)
        case let .sendFragment(address, data):
            w.tag(.sendFragment); w.str(address); w.data(data)
        case let .readIdentity(reqId, address):
            w.tag(.readIdentity); w.u32(reqId); w.str(address)
        case let .writeIdentity(address, identity):
            w.tag(.writeIdentity); w.str(address); w.data(identity)
        case let .readRemoteRssi(reqId, address):
            w.tag(.readRemoteRssi); w.u32(reqId); w.str(address)
        case let .closeConnection(address):
            w.tag(.closeConnection); w.str(address)
        case let .discovered(address, rssi, identity):
            w.tag(.discovered); w.str(address); w.i16(rssi); w.optData(identity)
        case let .incomingConnection(address, mtu, identity):
            w.tag(.incomingConnection); w.str(address); w.u16(mtu); w.optData(identity)
        case let .connectionLost(address):
            w.tag(.connectionLost); w.str(address)
        case let .receivedFragment(address, data):
            w.tag(.receivedFragment); w.str(address); w.data(data)
        case let .connectResult(reqId, address, mtu, identity, error):
            w.tag(.connectResult); w.u32(reqId); w.str(address); w.u16(mtu); w.optData(identity); w.optStr(error)
        case let .readIdentityResult(reqId, identity, error):
            w.tag(.readIdentityResult); w.u32(reqId); w.optData(identity); w.optStr(error)
        case let .readRemoteRssiResult(reqId, rssi, error):
            w.tag(.readRemoteRssiResult); w.u32(reqId); w.i16(rssi); w.optStr(error)
        case let .queryLocalStateResult(reqId, localAddress, isRunning):
            w.tag(.queryLocalStateResult); w.u32(reqId); w.optStr(localAddress); w.bool(isRunning)
        }
        return w.out
    }

    // MARK: Decode

    public init(decoding data: Data) throws {
        var r = SeamReader(data)
        let raw = try r.u8()
        guard let tag = Tag(rawValue: raw) else { throw SeamError.unknownTag(raw) }
        switch tag {
        case .startAdvertising: self = .startAdvertising
        case .stopAdvertising:  self = .stopAdvertising
        case .startScanning:    self = .startScanning
        case .stopScanning:     self = .stopScanning
        case .shutdown:         self = .shutdown
        case .connect:          self = .connect(reqId: try r.u32(), address: try r.str())
        case .disconnect:       self = .disconnect(address: try r.str())
        case .queryLocalState:  self = .queryLocalState(reqId: try r.u32())
        case .sendFragment:     self = .sendFragment(address: try r.str(), data: try r.data())
        case .readIdentity:     self = .readIdentity(reqId: try r.u32(), address: try r.str())
        case .writeIdentity:    self = .writeIdentity(address: try r.str(), identity: try r.data())
        case .readRemoteRssi:   self = .readRemoteRssi(reqId: try r.u32(), address: try r.str())
        case .closeConnection:  self = .closeConnection(address: try r.str())
        case .discovered:       self = .discovered(address: try r.str(), rssi: try r.i16(), identity: try r.optData())
        case .incomingConnection: self = .incomingConnection(address: try r.str(), mtu: try r.u16(), identity: try r.optData())
        case .connectionLost:   self = .connectionLost(address: try r.str())
        case .receivedFragment: self = .receivedFragment(address: try r.str(), data: try r.data())
        case .connectResult:    self = .connectResult(reqId: try r.u32(), address: try r.str(), mtu: try r.u16(), identity: try r.optData(), error: try r.optStr())
        case .readIdentityResult: self = .readIdentityResult(reqId: try r.u32(), identity: try r.optData(), error: try r.optStr())
        case .readRemoteRssiResult: self = .readRemoteRssiResult(reqId: try r.u32(), rssi: try r.i16(), error: try r.optStr())
        case .queryLocalStateResult: self = .queryLocalStateResult(reqId: try r.u32(), localAddress: try r.optStr(), isRunning: try r.bool())
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
    /// UInt16-length-prefixed blob (max 65535 — fine for fragments/identities/addresses).
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

/// Carries `BLEDriverSeamMessage`s across the App-Group. NE: `send` → the NE→app
/// queue, `inbound` ← the app→NE queue. App: reversed. Injected so both the NE
/// driver and the app server are unit-testable with an in-memory loopback.
public protocol BLESeamTransport: AnyObject, Sendable {
    func send(_ message: BLEDriverSeamMessage)
    /// Decoded messages arriving from the other process.
    var inbound: AsyncStream<BLEDriverSeamMessage> { get }
}

public enum BLESeamError: Error, Sendable {
    /// A reply arrived but wasn't the result type the request expected.
    case unexpectedReply
    /// The remote (app-side) driver reported a failure.
    case driver(String)
}
