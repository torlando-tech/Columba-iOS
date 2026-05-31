//
//  RNodeNativeBindings.swift
//  SwiftBLEBridge
//
//  C-ABI shims exposing SwiftRNodeBridge.shared to Python's ctypes. The Python
//  `IOSRNodeInterface` (app/rnode/IOSRNodeInterface.py) binds these via
//  `ctypes.CDLL(None)` at module import time — symbol names + signatures MUST
//  match the `_decl(...)` calls there. Mirror of `BleNativeBindings.swift`.
//
//  Return codes:
//    0  = success
//   -2  = argument error (null pointer / bad encoding)
//

import Foundation

// File-private decoders (Swift `private` is file-scoped, so these don't
// collide with the identically-purposed helpers in BleNativeBindings.swift).
private func rnodeDecodeCString(_ ptr: UnsafePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    return String(cString: ptr)
}

private func rnodeDecodeBytes(_ ptr: UnsafePointer<CChar>?, length: Int32) -> Data? {
    guard let ptr, length >= 0 else { return nil }
    if length == 0 { return Data() }
    return ptr.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { p in
        Data(bytes: p, count: Int(length))
    }
}

@_cdecl("columba_rnode_start")
public func columba_rnode_start() -> Int32 {
    SwiftRNodeBridge.shared.start()
    return 0
}

@_cdecl("columba_rnode_stop")
public func columba_rnode_stop() -> Int32 {
    SwiftRNodeBridge.shared.stop()
    return 0
}

@_cdecl("columba_rnode_connect")
public func columba_rnode_connect(_ deviceName: UnsafePointer<CChar>?) -> Int32 {
    guard let name = rnodeDecodeCString(deviceName) else { return -2 }
    SwiftRNodeBridge.shared.connect(deviceName: name)
    return 0
}

@_cdecl("columba_rnode_disconnect")
public func columba_rnode_disconnect() -> Int32 {
    SwiftRNodeBridge.shared.disconnect()
    return 0
}

@_cdecl("columba_rnode_write")
public func columba_rnode_write(
    _ bytes: UnsafePointer<CChar>?,
    _ length: Int32
) -> Int32 {
    guard let payload = rnodeDecodeBytes(bytes, length: length) else { return -2 }
    SwiftRNodeBridge.shared.write(payload)
    return 0
}
