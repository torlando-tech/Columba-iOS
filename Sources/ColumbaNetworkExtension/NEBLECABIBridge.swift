//
//  NEBLECABIBridge.swift
//  ColumbaNetworkExtension
//
//  NE-side implementation of the `columba_ble_*` C-ABI that `IOSBLEDriver.py`
//  resolves via `ctypes.CDLL(None)`. In the NE process the real CoreBluetooth
//  radio cannot run (CoreBluetooth is unavailable in a Network Extension), so
//  these symbols do NOT drive a radio directly - they forward the command over
//  the App-Group BLE seam to the app, where `SwiftBLEBridge` (the same
//  singleton the shipping Python path uses) performs the CoreBluetooth work.
//
//  This is the Model B analog of the app's `BleNativeBindings.swift`:
//  identical symbol names + signatures (so the unmodified Python driver works
//  in both processes), different back end (seam forwarder vs in-process radio).
//
//      NE:  IOSBLEDriver (Python) ──CDLL(None)──▶ NEBLECABIBridge (this file)
//                                                   │  AppGroupBLESeamTransport
//      app: AppGroupBLEServer ──▶ SwiftBLEBridge (real CoreBluetooth)
//
//  Return codes match the Python driver's contract: 0 = ok, -1 = not running,
//  -2 = bad arg.
//
//  Value-returning calls (`get_peer_role/mtu/rssi`) are answered from a small
//  local peer cache maintained by the inbound event stream, so the synchronous
//  ctypes call never blocks on a cross-process round trip.
//
//  Events app→NE are delivered to Python via `rns_bridge.invoke_ble_callback`
//  (a named function the NE calls through the embedded interpreter), so the
//  driver's registered callback slots fire exactly as in the app.
//

import Foundation

final class NEBLECABIBridge: @unchecked Sendable {
    static let shared = NEBLECABIBridge()

    private let transport: BLESeamTransport
    private let lock = NSLock()
    private var started = false
    private var inboundTask: Task<Void, Never>?

    /// Per-peer cache for the value-returning C-ABI calls. Updated by the
    /// inbound app→NE event stream.
    private struct Peer {
        var mtu: Int32 = 0
        var rssi: Int32 = Int32.min   // Int32.min = unknown (matches Python sentinel)
        var role: Int32 = 0           // 0 unknown, 1 central (we dialed), 2 peripheral (they dialed)
        var connected = false
    }
    private var peers: [String: Peer] = [:]

    private init() {
        transport = AppGroupBLESeamTransport(role: .networkExtension)
    }

    // MARK: - Lifecycle

    /// Begin consuming app→NE events. Idempotent. Called when the first BLE
    /// command arrives (the Python driver's `columba_ble_start`).
    func ensureStarted() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        transport.start()
        inboundTask = Task { [weak self] in
            guard let self else { return }
            for await msg in self.transport.inbound { self.handle(msg) }
        }
        ExtensionDiagLog.log("[BLE-NE] forwarder started; relaying app radio events to Python")
    }

    // MARK: - Command forwarding (NE Python → app radio)

    func sendStart(serviceUuid: String, rxCharUuid: String, txCharUuid: String, identityCharUuid: String) {
        ensureStarted()
        transport.send(.start(serviceUuid: serviceUuid, rxCharUuid: rxCharUuid, txCharUuid: txCharUuid, identityCharUuid: identityCharUuid))
    }
    func sendStop() { transport.send(.stop) }
    func sendSetIdentity(_ id: Data) { transport.send(.setIdentity(identity: id)) }
    func sendSyncExistingConnections() { transport.send(.syncExistingConnections) }
    func sendRequestIdentityResync(_ addr: String) { transport.send(.requestIdentityResync(address: addr)) }
    func sendStartScanning() { transport.send(.startScanning) }
    func sendStopScanning() { transport.send(.stopScanning) }
    func sendStartAdvertising(name: String, identity: Data) { transport.send(.startAdvertising(deviceName: name, identity: identity)) }
    func sendStopAdvertising() { transport.send(.stopAdvertising) }
    func sendConnect(_ addr: String) {
        lock.lock(); peers[addr, default: Peer()].role = 1; peers[addr]?.connected = true; lock.unlock()
        transport.send(.connect(address: addr))
    }
    func sendDisconnect(_ addr: String) { transport.send(.disconnect(address: addr)) }
    func send(_ addr: String, _ data: Data) { transport.send(.send(address: addr, data: data)) }
    func sendConfigurePower(_ name: String) {
        // tx power preset is informational on iOS; forward as a no-op dbm value.
        transport.send(.configurePower(address: "", txPowerDbm: 0))
    }

    // MARK: - Value queries (answered from the local peer cache)

    func peerRole(_ addr: String) -> Int32 { lock.lock(); defer { lock.unlock() }; return peers[addr]?.role ?? 0 }
    func peerMtu(_ addr: String) -> Int32 { lock.lock(); defer { lock.unlock() }; return peers[addr]?.mtu ?? 0 }
    func peerRssi(_ addr: String) -> Int32 { lock.lock(); defer { lock.unlock() }; return peers[addr]?.rssi ?? Int32.min }

    // MARK: - Inbound app→NE events → Python callbacks

    private func handle(_ msg: BLEDriverSeamMessage) {
        switch msg {
        case let .deviceDiscovered(addr, name, rssi):
            lock.lock(); peers[addr, default: Peer()].rssi = Int32(rssi); lock.unlock()
            invoke("on_device_discovered", address: addr, extra: ["name": name, "rssi": Int32(rssi), "service_uuids": []])

        case let .deviceConnected(addr, identity):
            lock.lock()
            var p = peers[addr] ?? Peer()
            p.connected = true
            if p.role == 0 { p.role = 2 }
            peers[addr] = p
            lock.unlock()
            var extra: [String: Any] = [:]
            if let id = identity { extra["identity_b64"] = id.base64EncodedString() }
            invoke("on_device_connected", address: addr, extra: extra)

        case let .deviceDisconnected(addr):
            lock.lock(); peers[addr]?.connected = false; lock.unlock()
            invoke("on_device_disconnected", address: addr, extra: [:])

        case let .dataReceived(addr, data):
            invoke("on_data_received", address: addr, extra: ["data_b64": data.base64EncodedString()])

        case let .mtuNegotiated(addr, mtu):
            lock.lock(); peers[addr, default: Peer()].mtu = Int32(mtu); lock.unlock()
            invoke("on_mtu_negotiated", address: addr, extra: ["mtu": Int32(mtu)])

        case let .identityReceived(addr, hex):
            invoke("on_identity_received", address: addr, extra: ["identity_hex": hex])

        case let .addressChanged(old, new, id):
            lock.lock()
            if let p = peers[old] { peers[new] = p; peers[old]?.connected = false }
            lock.unlock()
            invoke("on_address_changed", address: new, extra: ["old_address": old, "new_address": new, "identity_hash": id])

        case let .error(sev, message):
            invoke("on_error", address: "", extra: ["severity": sev, "message": message])

        case .start, .stop, .setIdentity, .startScanning, .stopScanning,
             .startAdvertising, .stopAdvertising, .connect, .disconnect, .send,
             .syncExistingConnections, .requestIdentityResync, .configurePower:
            break  // command direction; the forwarder never receives these
        }
    }

    /// Deliver an event to Python. The payload is JSON `{address, extra}` and
    /// the NE calls the named `rns_bridge.invoke_ble_callback` function through
    /// the embedded interpreter. The Python side expands `address`+`extra` into
    /// the driver's positional callback args.
    private func invoke(_ slot: String, address: String, extra: [String: Any]) {
        let payload: [String: Any] = ["slot": slot, "address": address, "extra": extra]
        NEPythonBridgeHook.shared.invoke(fn: "invoke_ble_callback", object: payload)
    }
}

// Indirection so the always-compiled C-ABI symbols can reach the NE Python
// runtime (which this file does not import). The NE wiring sets the hook once
// at startup; a nil hook degrades event delivery to a no-op (commands still
// forward to the app; the driver just stops receiving async events).
final class NEPythonBridgeHook: @unchecked Sendable {
    static let shared = NEPythonBridgeHook()
    private var fn: (@Sendable (String, [String: Any]) -> Void)?
    func setFn(_ f: @escaping @Sendable (String, [String: Any]) -> Void) { fn = f }
    func invoke(fn: String, object: [String: Any]) { self.fn?(fn, object) }

    /// Wire event delivery to the embedded Python interpreter: forward each
    /// event to `rns_bridge.invoke_ble_callback` through the NE's public
    /// `NEPythonRNS.invoke` seam (which serializes the kwargs and calls the
    /// named function through the embedded interpreter). Called once at NE
    /// startup (idempotent).
    static func wireToPython() {
        shared.setFn { fn, kwargs in
            NEPythonRNS.shared.invoke(fn, kwargs: kwargs)
        }
    }
}

// MARK: - C-ABI shims (mirror BleNativeBindings.swift symbol-for-symbol)

private func neble_cstr(_ ptr: UnsafePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    return String(cString: ptr)
}

private func neble_bytes(_ ptr: UnsafePointer<CChar>?, length: Int32) -> Data? {
    guard let ptr, length >= 0 else { return nil }
    if length == 0 { return Data() }
    return ptr.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { Data(bytes: $0, count: Int(length)) }
}

@_used
@_cdecl("columba_ble_start")
public func columba_ble_start(
    _ serviceUuid: UnsafePointer<CChar>?, _ rxCharUuid: UnsafePointer<CChar>?,
    _ txCharUuid: UnsafePointer<CChar>?, _ identityCharUuid: UnsafePointer<CChar>?
) -> Int32 {
    guard let s = neble_cstr(serviceUuid), let r = neble_cstr(rxCharUuid),
          let t = neble_cstr(txCharUuid), let i = neble_cstr(identityCharUuid) else { return -2 }
    NEBLECABIBridge.shared.sendStart(serviceUuid: s, rxCharUuid: r, txCharUuid: t, identityCharUuid: i)
    return 0
}

@_cdecl("columba_ble_stop")
public func columba_ble_stop() -> Int32 { NEBLECABIBridge.shared.sendStop(); return 0 }

@_cdecl("columba_ble_set_identity")
public func columba_ble_set_identity(_ bytes: UnsafePointer<CChar>?, _ length: Int32) -> Int32 {
    guard let data = neble_bytes(bytes, length: length) else { return -2 }
    NEBLECABIBridge.shared.sendSetIdentity(data); return 0
}

@_cdecl("columba_ble_sync_existing_connections")
public func columba_ble_sync_existing_connections() -> Int32 {
    NEBLECABIBridge.shared.sendSyncExistingConnections(); return 0
}

@_cdecl("columba_ble_request_identity_resync")
public func columba_ble_request_identity_resync(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let addr = neble_cstr(address) else { return -2 }
    NEBLECABIBridge.shared.sendRequestIdentityResync(addr); return 0
}

@_cdecl("columba_ble_start_scanning")
public func columba_ble_start_scanning() -> Int32 { NEBLECABIBridge.shared.sendStartScanning(); return 0 }

@_cdecl("columba_ble_stop_scanning")
public func columba_ble_stop_scanning() -> Int32 { NEBLECABIBridge.shared.sendStopScanning(); return 0 }

@_cdecl("columba_ble_start_advertising")
public func columba_ble_start_advertising(
    _ deviceName: UnsafePointer<CChar>?, _ identityBytes: UnsafePointer<CChar>?, _ identityLength: Int32
) -> Int32 {
    let name = neble_cstr(deviceName)
    let identity = neble_bytes(identityBytes, length: identityLength) ?? Data()
    NEBLECABIBridge.shared.sendStartAdvertising(name: name ?? "", identity: identity); return 0
}

@_cdecl("columba_ble_stop_advertising")
public func columba_ble_stop_advertising() -> Int32 { NEBLECABIBridge.shared.sendStopAdvertising(); return 0 }

@_cdecl("columba_ble_connect")
public func columba_ble_connect(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let addr = neble_cstr(address) else { return -2 }
    NEBLECABIBridge.shared.sendConnect(addr); return 0
}

@_cdecl("columba_ble_disconnect")
public func columba_ble_disconnect(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let addr = neble_cstr(address) else { return -2 }
    NEBLECABIBridge.shared.sendDisconnect(addr); return 0
}

@_cdecl("columba_ble_send")
public func columba_ble_send(
    _ address: UnsafePointer<CChar>?, _ data: UnsafePointer<CChar>?, _ length: Int32
) -> Int32 {
    guard let addr = neble_cstr(address), let payload = neble_bytes(data, length: length) else { return -2 }
    NEBLECABIBridge.shared.send(addr, payload); return 0
}

@_cdecl("columba_ble_get_peer_role")
public func columba_ble_get_peer_role(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let addr = neble_cstr(address) else { return -2 }
    return NEBLECABIBridge.shared.peerRole(addr)
}

@_cdecl("columba_ble_get_peer_mtu")
public func columba_ble_get_peer_mtu(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let addr = neble_cstr(address) else { return -2 }
    return NEBLECABIBridge.shared.peerMtu(addr)
}

@_cdecl("columba_ble_get_peer_rssi")
public func columba_ble_get_peer_rssi(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let addr = neble_cstr(address) else { return Int32.min }
    return NEBLECABIBridge.shared.peerRssi(addr)
}

@_cdecl("columba_ble_configure_power")
public func columba_ble_configure_power(_ presetName: UnsafePointer<CChar>?) -> Int32 {
    guard let name = neble_cstr(presetName) else { return -2 }
    NEBLECABIBridge.shared.sendConfigurePower(name); return 0
}
