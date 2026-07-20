//
//  BleNativeBindings.swift
//  SwiftBLEBridge
//
//  C-ABI shims exposing SwiftBLEBridge.shared to Python's ctypes. The Python
//  `IOSBLEDriver` (app/ble/IOSBLEDriver.py) binds these via `ctypes.CDLL(None)`
//  at module import time. Symbol names MUST match the `_decl(...)` calls there.
//
//  Return codes:
//    0  = success
//   -1  = bridge not started / invalid state
//   -2  = argument error (null pointer, bad encoding)
//   -3  = bridge call threw
//

import Foundation

/// Ordinary Swift reference used by the app target to force this source file
/// out of SwiftPM's static archive. The @_used C exports below can only resist
/// dead stripping after the archive member itself has been linked.
@inline(never)
public func columbaBLEForceLinkNativeBindings() {}

// MARK: - Helpers

private func decodeCString(_ ptr: UnsafePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    return String(cString: ptr)
}

private func decodeBytes(_ ptr: UnsafePointer<CChar>?, length: Int32) -> Data? {
    guard let ptr, length >= 0 else { return nil }
    if length == 0 { return Data() }
    return ptr.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { p in
        Data(bytes: p, count: Int(length))
    }
}

// MARK: - Lifecycle

@_used
@_cdecl("columba_ble_start")
public func columba_ble_start(
    _ serviceUuid: UnsafePointer<CChar>?,
    _ rxCharUuid: UnsafePointer<CChar>?,
    _ txCharUuid: UnsafePointer<CChar>?,
    _ identityCharUuid: UnsafePointer<CChar>?
) -> Int32 {
    guard let s = decodeCString(serviceUuid),
          let r = decodeCString(rxCharUuid),
          let t = decodeCString(txCharUuid),
          let i = decodeCString(identityCharUuid) else {
        return -2
    }
    SwiftBLEBridge.shared.start(
        serviceUuid: s,
        rxCharUuid: r,
        txCharUuid: t,
        identityCharUuid: i
    )
    return 0
}

@_used
@_cdecl("columba_ble_stop")
public func columba_ble_stop() -> Int32 {
    SwiftBLEBridge.shared.stop()
    return 0
}

@_used
@_cdecl("columba_ble_set_identity")
public func columba_ble_set_identity(
    _ bytes: UnsafePointer<CChar>?,
    _ length: Int32
) -> Int32 {
    guard let data = decodeBytes(bytes, length: length) else { return -2 }
    SwiftBLEBridge.shared.setIdentity(data)
    return 0
}

@_used
@_cdecl("columba_ble_sync_existing_connections")
public func columba_ble_sync_existing_connections() -> Int32 {
    SwiftBLEBridge.shared.syncExistingConnections()
    return 0
}

@_used
@_cdecl("columba_ble_request_identity_resync")
public func columba_ble_request_identity_resync(
    _ address: UnsafePointer<CChar>?
) -> Int32 {
    guard let addr = decodeCString(address) else { return -2 }
    return SwiftBLEBridge.shared.requestIdentityResync(address: addr) ? 0 : -1
}

// MARK: - Scan + advertise

@_used
@_cdecl("columba_ble_start_scanning")
public func columba_ble_start_scanning() -> Int32 {
    SwiftBLEBridge.shared.startScanning()
    return 0
}

@_used
@_cdecl("columba_ble_stop_scanning")
public func columba_ble_stop_scanning() -> Int32 {
    SwiftBLEBridge.shared.stopScanning()
    return 0
}

@_used
@_cdecl("columba_ble_start_advertising")
public func columba_ble_start_advertising(
    _ deviceName: UnsafePointer<CChar>?,
    _ identityBytes: UnsafePointer<CChar>?,
    _ identityLength: Int32
) -> Int32 {
    let name = decodeCString(deviceName)
    let identity = decodeBytes(identityBytes, length: identityLength) ?? Data()
    SwiftBLEBridge.shared.setIdentity(identity)
    SwiftBLEBridge.shared.startAdvertising(deviceName: name?.isEmpty == false ? name : nil)
    return 0
}

@_used
@_cdecl("columba_ble_stop_advertising")
public func columba_ble_stop_advertising() -> Int32 {
    SwiftBLEBridge.shared.stopAdvertising()
    return 0
}

// MARK: - Connection management

@_used
@_cdecl("columba_ble_connect")
public func columba_ble_connect(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let addr = decodeCString(address) else { return -2 }
    SwiftBLEBridge.shared.connect(address: addr)
    return 0
}

@_used
@_cdecl("columba_ble_disconnect")
public func columba_ble_disconnect(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let addr = decodeCString(address) else { return -2 }
    SwiftBLEBridge.shared.disconnect(address: addr)
    return 0
}

@_used
@_cdecl("columba_ble_send")
public func columba_ble_send(
    _ address: UnsafePointer<CChar>?,
    _ data: UnsafePointer<CChar>?,
    _ length: Int32
) -> Int32 {
    guard let addr = decodeCString(address),
          let payload = decodeBytes(data, length: length) else {
        return -2
    }
    return SwiftBLEBridge.shared.send(address: addr, data: payload) ? 0 : -1
}

/// Return 1 for a central-role link, 2 for peripheral, 0 when unknown.
@_used
@_cdecl("columba_ble_get_peer_role")
public func columba_ble_get_peer_role(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let addr = decodeCString(address) else { return -2 }
    switch SwiftBLEBridge.shared.getPeerRole(address: addr) {
    case .central: return 1
    case .peripheral: return 2
    case nil: return 0
    }
}

/// Return the usable GATT payload size, or 0 when the peer is not established.
@_used
@_cdecl("columba_ble_get_peer_mtu")
public func columba_ble_get_peer_mtu(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let addr = decodeCString(address) else { return -2 }
    return Int32(SwiftBLEBridge.shared.getPeerMtu(address: addr) ?? 0)
}

// MARK: - Config

@_used
@_cdecl("columba_ble_configure_power")
public func columba_ble_configure_power(_ presetName: UnsafePointer<CChar>?) -> Int32 {
    guard let name = decodeCString(presetName),
          let preset = BlePowerPreset(rawValue: name) else {
        return -2
    }
    SwiftBLEBridge.shared.configurePower(BlePowerSettings(preset: preset))
    return 0
}
