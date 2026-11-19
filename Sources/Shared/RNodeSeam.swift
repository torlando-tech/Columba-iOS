//
//  RNodeSeam.swift
//  Shared
//
//  The NE↔app marshaling types for RNode-over-Bluetooth. Python RNS ships the
//  RNode protocol stack (`IOSRNodeInterface` + KISS framing) and the CoreBluetooth
//  NUS client (`PythonRNodeBLEBridge`) — the latter must run in the app process,
//  while the node may run in the Network Extension. The cross-process seam
//  endpoints (the old Swift `AppGroupRNodeSeamTransport` / `AppGroupRNodeServer`)
//  were retired with the Swift node; the live survivor here is `RNodeSeamConfig`
//  (app → App-Group → Python node), and the wire types below remain for the
//  RNodeSeam contract tests.
//
//      node: IOSRNodeInterface ──KISS──▶ seam / in-process driver
//                                              │  (App-Group or ctypes)
//      app: PythonRNodeBLEBridge (real NUS) ◀──┘
//
//  Unlike the BLE *mesh* seam, RNode is a SINGLE raw serial stream with no
//  multi-peer addressing, so this wire is tiny: the NE drives connect/send/disconnect
//  on the app's real `BLETransport`, and the app feeds received bytes + radio
//  state-changes back. The KISS framing lives in the NE (`KISSFramedTransport`), so
//  the bytes that cross this seam are the raw serial stream — `send` carries already
//  KISS-framed output, `dataReceived` carries raw input awaiting deframing.
//
//  Reuses the `SeamWriter`/`SeamReader` binary codec from `BLEDriverSeam.swift`
//  (same Shared module). Direction is by transport queue, not by type.
//

import Foundation

// MARK: - Link state

/// Compact wire form of the transport link state, carried app→NE on
/// `stateChanged`. The seam endpoints map their native transport states to and
/// from this. Kept here (Foundation-only) so the wire definition needs no
/// protocol-package import.
public enum RNodeLinkState: UInt8, Sendable, Equatable {
    case disconnected = 0
    case connecting   = 1
    case connected    = 2
    case failed       = 3
}

// MARK: - Message

/// One message on the RNode serial seam.
public enum RNodeSeamMessage: Equatable, Sendable {
    // ── Commands: NE → app (drive the app's real RNode `BLETransport`) ──
    /// Begin scanning/connecting to the named RNode (the device name the NE is
    /// configured with — `config.host`). Empty string = connect to the first RNode found.
    case connect(deviceName: String)
    /// Outbound serial bytes (already KISS-framed by the NE) to write to the radio.
    /// `reqId` correlates with the matching `sendResult` so the NE's
    /// `send(_:completion:)` completes only when the app's real write completes —
    /// RNode flow control relies on write-completion (see
    /// `RNodeInterface.sendViaTransport`, which awaits the completion before the next
    /// queued packet is sent).
    case send(reqId: UInt32, data: Data)
    /// Tear the radio link down.
    case disconnect

    // ── Events: app → NE (feed the NE's seam `Transport`) ──
    /// Inbound serial bytes from the radio (raw, awaiting KISS deframing in the NE).
    case dataReceived(data: Data)
    /// The app radio's `TransportState` changed. `reason` carries the underlying failure
    /// description (e.g. the `BLEError` copy — "Bluetooth permission denied", "Connection
    /// timed out…") on `.failed`, nil otherwise, so the NE/UI can show an actionable
    /// message instead of a bare "failed".
    case stateChanged(state: RNodeLinkState, reason: String?)
    /// Completion of a `send(reqId:)` — carries the app-side write error (nil = ok)
    /// so the NE can resume the awaiting `send` continuation (flow control).
    case sendResult(reqId: UInt32, error: String?)

    private enum Tag: UInt8 {
        case connect = 1, send, disconnect
        case dataReceived = 64, stateChanged, sendResult
    }

    /// Metadata-only description for logs (NO-PII: never the `Data` payload
    /// bytes of `.send` / `.dataReceived`). Byte counts only.
    var diagnosticLabel: String {
        switch self {
        case .connect: "connect"
        case .send(let reqId, let data): "send(reqId=\(reqId), \(data.count)B)"
        case .disconnect: "disconnect"
        case .dataReceived(let data): "dataReceived(\(data.count)B)"
        case .stateChanged(let state, _): "stateChanged(\(state.rawValue))"
        case .sendResult(let reqId, _): "sendResult(reqId=\(reqId))"
        }
    }

    // MARK: Encode

    public func encode() -> Data {
        var w = SeamWriter()
        switch self {
        case let .connect(deviceName): w.u8(Tag.connect.rawValue); w.str(deviceName)
        case .disconnect:              w.u8(Tag.disconnect.rawValue)
        case let .send(reqId, data):   w.u8(Tag.send.rawValue); w.u32(reqId); w.data(data)
        case let .dataReceived(data):  w.u8(Tag.dataReceived.rawValue); w.data(data)
        case let .stateChanged(state, reason): w.u8(Tag.stateChanged.rawValue); w.u8(state.rawValue); w.optStr(reason)
        case let .sendResult(reqId, error): w.u8(Tag.sendResult.rawValue); w.u32(reqId); w.optStr(error)
        }
        return w.out
    }

    // MARK: Decode

    public init(decoding data: Data) throws {
        var r = SeamReader(data)
        let raw = try r.u8()
        guard let tag = Tag(rawValue: raw) else { throw SeamError.unknownTag(raw) }
        switch tag {
        case .connect:      self = .connect(deviceName: try r.str())
        case .disconnect:   self = .disconnect
        case .send:         self = .send(reqId: try r.u32(), data: try r.data())
        case .dataReceived: self = .dataReceived(data: try r.data())
        case .stateChanged:
            let s = try r.u8()
            guard let state = RNodeLinkState(rawValue: s) else { throw SeamError.unknownTag(s) }
            self = .stateChanged(state: state, reason: try r.optStr())
        case .sendResult:   self = .sendResult(reqId: try r.u32(), error: try r.optStr())
        }
        try r.expectEnd()
    }
}

// MARK: - Wire abstraction

/// Carries `RNodeSeamMessage`s across the App-Group. NE: `send` → the NE→app queue,
/// `inbound` ← the app→NE queue. App: reversed. Injected so both seam endpoints
/// are unit-testable with an in-memory loopback. Mirrors `BLESeamTransport`.
public protocol RNodeSeamWire: AnyObject, Sendable {
    func send(_ message: RNodeSeamMessage)
    /// Decoded messages arriving from the other process.
    var inbound: AsyncStream<RNodeSeamMessage> { get }
    /// Begin/stop delivering on `inbound` (and any underlying observers). The app-group
    /// impl wires Darwin observers; an in-memory test loopback can no-op these.
    func start()
    func stop()
}

// MARK: - Shared config snapshot

/// Foundation-only snapshot of the RNode radio configuration, persisted by the app to
/// the App-Group `rnodeConfigKey` and read by the NE. Fields mirror the app's
/// `RNodeConfig` (in RNSAPI, which the NE does not link); the Python node maps
/// these to RNS `RadioConfig`.
public struct RNodeSeamConfig: Codable, Equatable, Sendable {
    public var deviceName: String
    public var frequency: UInt32
    public var bandwidth: UInt32
    public var txPower: UInt8
    public var spreadingFactor: UInt8
    public var codingRate: UInt8
    public var stAlock: Float?
    public var ltAlock: Float?

    public init(
        deviceName: String,
        frequency: UInt32,
        bandwidth: UInt32,
        txPower: UInt8,
        spreadingFactor: UInt8,
        codingRate: UInt8,
        stAlock: Float? = nil,
        ltAlock: Float? = nil
    ) {
        self.deviceName = deviceName
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.txPower = txPower
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
        self.stAlock = stAlock
        self.ltAlock = ltAlock
    }

    // MARK: App-Group persistence

    /// Read the persisted RNode config, or nil if no RNode is enabled.
    public static func loadFromAppGroup(_ group: String = appGroupIdentifier) -> RNodeSeamConfig? {
        guard let defaults = UserDefaults(suiteName: group),
              let data = defaults.data(forKey: SharedDefaultsConstants.rnodeConfigKey),
              let config = try? JSONDecoder().decode(RNodeSeamConfig.self, from: data) else {
            return nil
        }
        return config
    }

    /// Persist this config to the App-Group (app side) + post the change notification.
    public func saveToAppGroup(_ group: String = appGroupIdentifier) {
        guard let defaults = UserDefaults(suiteName: group),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SharedDefaultsConstants.rnodeConfigKey)
        Self.postChangedNotification()
    }

    /// Clear the persisted config (RNode disabled) + post the change notification.
    public static func clearFromAppGroup(_ group: String = appGroupIdentifier) {
        UserDefaults(suiteName: group)?.removeObject(forKey: SharedDefaultsConstants.rnodeConfigKey)
        postChangedNotification()
    }

    private static func postChangedNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(SharedDefaultsConstants.rnodeConfigChangedNotificationName as CFString),
            nil, nil, true
        )
    }
}
