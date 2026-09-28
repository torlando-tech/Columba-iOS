//
//  PythonRNodeSessionDriver.swift
//  ColumbaApp
//
//  ColumbaApp-side `RNodeSessionRadioDriver` for the Model B Python RNode
//  session seam. Wraps the shipping `PythonRNodeBLESessionRegistry` (the
//  CoreBluetooth NUS byte-stream owner, ReticulumSwift-free) so the
//  `AppGroupRNodeSessionServer` (in the Shared module, which cannot import
//  CoreBluetooth) can drive it.
//
//  The registry is the SAME singleton the in-app Python backend already uses in
//  Model A, so there is exactly one CoreBluetooth NUS radio per process - the
//  Model B seam just reaches it across the App-Group. No reticulum-swift here:
//  Python owns RNS/KISS, this driver owns only the native BLE byte stream.
//

import Foundation

final class PythonRNodeSessionDriver: RNodeSessionRadioDriver, @unchecked Sendable {

    private let registry = PythonRNodeBLESessionRegistry.shared

    @discardableResult
    func openSession(deviceName: String, deviceIdentifier: String?) -> Int32 {
        registry.open(deviceName: deviceName, deviceIdentifier: deviceIdentifier)
    }

    func closeSession(radioHandle: Int32) {
        registry.close(handle: radioHandle)
    }

    func state(radioHandle: Int32) -> (RNodeSessionLinkState, String?)? {
        guard let (state, reason) = registry.snapshot(handle: radioHandle) else { return nil }
        // Map the app's PythonRNodeLinkState -> the seam's wire form. Values
        // are identical (0 disconnected, 1 connecting, 2 connected, 3 failed).
        return (RNodeSessionLinkState(rawValue: UInt8(state.rawValue)) ?? .disconnected, reason)
    }

    func failure(radioHandle: Int32) -> Int32 {
        registry.failureCode(handle: radioHandle).rawValue
    }

    func read(radioHandle: Int32) -> Data {
        registry.read(handle: radioHandle, maxBytes: 65536) ?? Data()
    }

    @discardableResult
    func write(radioHandle: Int32, data: Data) -> Int32 {
        Int32(registry.write(handle: radioHandle, data: data))
    }

    @discardableResult
    func setOnline(radioHandle: Int32, online: Bool) -> Bool {
        registry.setInterfaceOnline(handle: radioHandle, online: online)
    }
}
