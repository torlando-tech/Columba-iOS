//
//  RNodeSessionSeam.swift
//  Shared
//
//  The NE↔app marshaling for the PYTHON RNode session driver (IOSRNodeDriver /
//  IOSRNodeInterface) in Model B. The NE's embedded Python RNS runs the RNode
//  interface; the CoreBluetooth NUS radio cannot run in a Network Extension, so
//  the C-ABI symbols the driver resolves via CDLL(None) (`columba_rnode_session_*`)
//  are implemented in the NE (`NERNodeCABIBridge`) and forwarded over this seam
//  to the app, where `PythonRNodeBLESessionRegistry` (the shipping CoreBluetooth
//  owner) performs the real radio work.
//
//      NE:  IOSRNodeDriver (Python) ──CDLL(None)──▶ NERNodeCABIBridge (this file's twin)
//                                                   │  AppGroupRNodeSessionTransport
//      app: AppGroupRNodeSessionServer ──▶ PythonRNodeBLESessionRegistry (CoreBluetooth NUS)
//
//  Unlike the BLE *mesh* seam (event-push, per-peer cache), the Python RNode driver is
//  a POLL-BASED session-handle model:
//
//      open(name, id) -> handle          (NE allocates a local handle, returns it)
//      while state(handle) == CONNECTING { sleep(50ms) }
//      while online: read(handle) / writeSync(handle) in a tight loop
//      close(handle)
//
//  So the NE answers `state` / `read` / `failure` from LOCAL caches that the app
//  feeds via the inbound event stream (no cross-process round-trip on the hot path),
//  and forwards `open` / `write` / `close` / `setOnline` to the app. `write` carries a
//  `reqId` so the NE's `writeSync` can report the real byte count (the Python driver
//  checks `written == len(data)`) - the app answers with `writeResult`.
//
//  Reuses the `SeamWriter` / `SeamReader` binary codec from `BLEDriverSeam.swift`
//  (same Shared module). Direction is by transport queue, not by type.
//
//  This file imports ONLY Foundation and is compiled into BOTH the ColumbaApp and
//  ColumbaNetworkExtension targets. It must stay free of ReticulumSwift / RNSAPI so it
//  compiles in the NE target (which does not link those).
//

import Foundation

// MARK: - Link state (mirrors PythonRNodeLinkState)

/// Compact wire form of the app's `PythonRNodeLinkState`, carried app→NE on
/// `stateChanged`. Values match `PythonRNodeLinkState` (0 disconnected, 1
/// connecting, 2 connected, 3 failed) so the NE can pass them straight to the
/// Python driver's `columba_rnode_session_state`.
public enum RNodeSessionLinkState: UInt8, Sendable, Equatable {
    case disconnected = 0
    case connecting   = 1
    case connected    = 2
    case failed       = 3
}

// MARK: - Message

/// One message on the RNode session seam.
public enum RNodeSessionSeamMessage: Equatable, Sendable {
    // ── Commands: NE → app (drive the app's PythonRNodeBLESessionRegistry) ──
    /// Open a session for the named RNode. `deviceIdentifier` is the CoreBluetooth
    /// stable UUID (when known) or nil (legacy name-keyed). The app allocates its own
    /// registry handle for the session.
    case open(deviceName: String, deviceIdentifier: String?)
    /// Close the session identified by `deviceName` + `deviceIdentifier`. The NE
    /// already dropped its local cache; this tells the app to release the radio.
    case close(deviceName: String, deviceIdentifier: String?)
    /// Outbound serial bytes (already KISS-framed by the NE) to write to the radio.
    /// `reqId` correlates with the matching `writeResult` so the NE's `writeSync`
    /// reports the real byte count (the Python driver checks `written == len(data)`).
    case write(deviceName: String, deviceIdentifier: String?, reqId: UInt32, data: Data)
    /// RNS signals the interface is online / offline (drives the app's reported state:
    /// CONNECTED stays CONNECTING until online=true, so the driver's poll sees
    /// CONNECTING until RNS is actually ready).
    case setOnline(deviceName: String, deviceIdentifier: String?, online: Bool)

    // ── Events: app → NE (feed the NE's local session caches) ──
    /// The app radio's link state changed for the session identified by
    /// `deviceName` + `deviceIdentifier`. `reason` carries the failure description
    /// on `.failed`, nil otherwise.
    case stateChanged(deviceName: String, deviceIdentifier: String?, state: RNodeSessionLinkState, reason: String?)
    /// Inbound serial bytes from the radio (raw, awaiting KISS deframing in the NE).
    case dataReceived(deviceName: String, deviceIdentifier: String?, data: Data)
    /// Completion of a `write(reqId:)` - carries the app-side written byte count
    /// (== data count on success, negative on error) so the NE's `writeSync` can
    /// return the real value to the Python driver.
    case writeResult(deviceName: String, deviceIdentifier: String?, reqId: UInt32, written: Int32)
    /// The app radio's typed failure code for the session (0 none, 1 failed, 2
    /// pairing_required) - mirrors `columba_rnode_session_failure`.
    case failureChanged(deviceName: String, deviceIdentifier: String?, code: Int32)

    private enum Tag: UInt8 {
        case open = 1, close, write, setOnline
        case stateChanged = 64, dataReceived, writeResult, failureChanged
    }

    /// Metadata-only description for logs (NO-PII: never the `Data` payload bytes).
    var diagnosticLabel: String {
        switch self {
        case let .open(name, _): "open('\(name)')"
        case let .close(name, _): "close('\(name)')"
        case let .write(name, _, reqId, data): "write('\(name)', reqId=\(reqId), \(data.count)B)"
        case let .setOnline(name, _, online): "setOnline('\(name)', \(online))"
        case let .stateChanged(name, _, state, _): "stateChanged('\(name)', \(state.rawValue))"
        case let .dataReceived(name, _, data): "dataReceived('\(name)', \(data.count)B)"
        case let .writeResult(name, _, reqId, written): "writeResult('\(name)', reqId=\(reqId), \(written))"
        case let .failureChanged(name, _, code): "failureChanged('\(name)', \(code))"
        }
    }

    // MARK: Encode

    public func encode() -> Data {
        var w = SeamWriter()
        switch self {
        case let .open(name, id):
            w.u8(Tag.open.rawValue); w.str(name); w.optStr(id)
        case let .close(name, id):
            w.u8(Tag.close.rawValue); w.str(name); w.optStr(id)
        case let .write(name, id, reqId, data):
            w.u8(Tag.write.rawValue); w.str(name); w.optStr(id); w.u32(reqId); w.data(data)
        case let .setOnline(name, id, online):
            w.u8(Tag.setOnline.rawValue); w.str(name); w.optStr(id); w.bool(online)
        case let .stateChanged(name, id, state, reason):
            w.u8(Tag.stateChanged.rawValue); w.str(name); w.optStr(id)
            w.u8(state.rawValue); w.optStr(reason)
        case let .dataReceived(name, id, data):
            w.u8(Tag.dataReceived.rawValue); w.str(name); w.optStr(id); w.data(data)
        case let .writeResult(name, id, reqId, written):
            w.u8(Tag.writeResult.rawValue); w.str(name); w.optStr(id); w.u32(reqId); w.i32(written)
        case let .failureChanged(name, id, code):
            w.u8(Tag.failureChanged.rawValue); w.str(name); w.optStr(id); w.i32(code)
        }
        return w.out
    }

    // MARK: Decode

    public init(decoding data: Data) throws {
        var r = SeamReader(data)
        let raw = try r.u8()
        guard let tag = Tag(rawValue: raw) else { throw SeamError.unknownTag(raw) }
        switch tag {
        case .open:
            self = .open(deviceName: try r.str(), deviceIdentifier: try r.optStr())
        case .close:
            self = .close(deviceName: try r.str(), deviceIdentifier: try r.optStr())
        case .write:
            self = .write(deviceName: try r.str(), deviceIdentifier: try r.optStr(),
                          reqId: try r.u32(), data: try r.data())
        case .setOnline:
            self = .setOnline(deviceName: try r.str(), deviceIdentifier: try r.optStr(),
                              online: try r.bool())
        case .stateChanged:
            self = .stateChanged(deviceName: try r.str(), deviceIdentifier: try r.optStr(),
                                 state: RNodeSessionLinkState(rawValue: try r.u8()) ?? .disconnected,
                                 reason: try r.optStr())
        case .dataReceived:
            self = .dataReceived(deviceName: try r.str(), deviceIdentifier: try r.optStr(),
                                 data: try r.data())
        case .writeResult:
            self = .writeResult(deviceName: try r.str(), deviceIdentifier: try r.optStr(),
                                reqId: try r.u32(), written: try r.i32())
        case .failureChanged:
            self = .failureChanged(deviceName: try r.str(), deviceIdentifier: try r.optStr(),
                                   code: try r.i32())
        }
        try r.expectEnd()
    }
}

// MARK: - Wire abstraction

/// Carries `RNodeSessionSeamMessage`s across the App-Group. NE: `send` → the NE→app
/// queue, `inbound` ← the app→NE queue. App: reversed. Injected so both the NE-side
/// forwarder and the app-side server are unit-testable with an in-memory loopback.
/// Mirrors `BLESeamTransport`.
public protocol RNodeSessionSeamWire: AnyObject, Sendable {
    func send(_ message: RNodeSessionSeamMessage)
    /// Decoded messages arriving from the other process.
    var inbound: AsyncStream<RNodeSessionSeamMessage> { get }
    /// Begin/stop delivering on `inbound` (and any underlying observers). The app-group
    /// impl wires Darwin observers; an in-memory test loopback can no-op these.
    func start()
    func stop()
}
