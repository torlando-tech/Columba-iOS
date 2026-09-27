//
//  AppGroupBLEServer.swift
//  Shared
//
//  App side of the Model B BLE seam. Consumes the NE's `columba_ble_*` commands
//  off the seam and drives a `BleRadioDriver`; forwards the driver's events back
//  over the seam as `BLEDriverSeamMessage`s.
//
//  This file is DRIVER-AGNOSTIC and compiled into both the app and the NE, so it
//  must NOT import CoreBluetooth / SwiftBLEBridge (unavailable in a Network
//  Extension). The concrete radio is `SwiftBLEBridge.shared` (the same singleton
//  the shipping Python path uses — exactly one CoreBluetooth radio per process),
//  wrapped by an app-only `BleRadioDriver` in `ModelBBLEService`.
//
//  No reticulum-swift: the driver-level abstraction lives in Python
//  (`IOSBLEDriver`, the Android-parity `BLEDriverInterface`); this server is only
//  the relay between the seam and the radio. See `BLEDriverSeam.swift` for the
//  wire and `NEBLECABIBridge.swift` (NE) for the C-ABI side.
//

import Foundation

/// The CoreBluetooth radio the server drives. App-only implementation wraps
/// `SwiftBLEBridge.shared`; the NE never instantiates a driver (it forwards the
/// Python driver's C-ABI calls over the seam instead).
public protocol BleRadioDriver: AnyObject {
    func radioStart(serviceUuid: String, rxCharUuid: String, txCharUuid: String, identityCharUuid: String)
    func radioStop()
    func radioSetIdentity(_ identity: Data)
    func radioStartScanning()
    func radioStopScanning()
    func radioStartAdvertising(deviceName: String?, identity: Data)
    func radioStopAdvertising()
    func radioConnect(address: String)
    func radioDisconnect(address: String)
    func radioSend(address: String, data: Data)
    func radioSyncExistingConnections()
    func radioRequestIdentityResync(address: String)
    /// Install the sink the driver pushes async events into (nil to detach).
    func setEventSink(_ sink: BleEventSink?)
}

/// Sink for radio events; the server forwards each as a seam message app→NE.
public protocol BleEventSink: AnyObject {
    func radioDeviceDiscovered(address: String, name: String, rssi: Int16)
    func radioDeviceConnected(address: String, peerIdentity: Data?)
    func radioDeviceDisconnected(address: String)
    func radioDataReceived(address: String, data: Data)
    func radioMtuNegotiated(address: String, mtu: UInt16)
    func radioIdentityReceived(address: String, identityHex: String)
    func radioAddressChanged(old: String, new: String, identityHash: String)
    func radioError(severity: String, message: String)
}

/// Relays seam commands → radio and radio events → seam.
public final class AppGroupBLEServer: BleEventSink, @unchecked Sendable {

    private let transport: BLESeamTransport
    private let driver: BleRadioDriver
    private var inboundTask: Task<Void, Never>?
    private let log: (@Sendable (String) -> Void)?

    public init(transport: BLESeamTransport, driver: BleRadioDriver,
                log: (@Sendable (String) -> Void)? = nil) {
        self.transport = transport
        self.driver = driver
        self.log = log
    }

    /// Begin consuming NE commands + relaying radio events to the seam.
    /// Idempotent (the inbound task is cancelled/restarted; setEventSink is
    /// safe to re-set).
    public func start() {
        log?("[BLE] server: starting — relaying seam commands to the radio")
        transport.start()
        driver.setEventSink(self)
        inboundTask?.cancel()
        inboundTask = Task { [weak self] in
            guard let self else { return }
            for await msg in self.transport.inbound { await self.handle(msg) }
        }
    }

    public func stop() {
        driver.setEventSink(nil)
        inboundTask?.cancel()
        inboundTask = nil
        transport.stop()
    }

    // MARK: Command dispatch (NE → radio)

    private func handle(_ message: BLEDriverSeamMessage) async {
        switch message {
        case let .start(s, rx, tx, id):
            log?("[BLE] server: start (service=\(s.prefix(8))…)")
            driver.radioStart(serviceUuid: s, rxCharUuid: rx, txCharUuid: tx, identityCharUuid: id)
        case .stop:
            driver.radioStop()
        case let .setIdentity(id):
            driver.radioSetIdentity(id)
        case .startScanning:
            driver.radioStartScanning(); log?("[BLE] server: startScanning")
        case .stopScanning:
            driver.radioStopScanning()
        case let .startAdvertising(name, identity):
            driver.radioStartAdvertising(deviceName: name.isEmpty ? nil : name, identity: identity)
            log?("[BLE] server: startAdvertising (name='\(name)')")
        case .stopAdvertising:
            driver.radioStopAdvertising()
        case let .connect(addr):
            driver.radioConnect(address: addr); log?("[BLE] server: connect → \(addr.prefix(8))")
        case let .disconnect(addr):
            driver.radioDisconnect(address: addr)
        case let .send(addr, data):
            driver.radioSend(address: addr, data: data)
        case .syncExistingConnections:
            driver.radioSyncExistingConnections()
        case let .requestIdentityResync(addr):
            driver.radioRequestIdentityResync(address: addr)
        case .configurePower:
            // tx power preset is informational on iOS (OS auto-manages duty
            // cycle); no per-peer power API in this slice.
            break
        case .deviceDiscovered, .deviceConnected, .deviceDisconnected,
             .dataReceived, .mtuNegotiated, .identityReceived, .addressChanged, .error:
            break  // events flow app→NE; the server never receives them as inbound
        }
    }

    // MARK: Radio event sink (radio → seam, app→NE)

    public func radioDeviceDiscovered(address: String, name: String, rssi: Int16) {
        transport.send(.deviceDiscovered(address: address, name: name, rssi: rssi))
    }
    public func radioDeviceConnected(address: String, peerIdentity: Data?) {
        transport.send(.deviceConnected(address: address, peerIdentity: peerIdentity))
    }
    public func radioDeviceDisconnected(address: String) {
        transport.send(.deviceDisconnected(address: address))
    }
    public func radioDataReceived(address: String, data: Data) {
        transport.send(.dataReceived(address: address, data: data))
    }
    public func radioMtuNegotiated(address: String, mtu: UInt16) {
        transport.send(.mtuNegotiated(address: address, mtu: mtu))
    }
    public func radioIdentityReceived(address: String, identityHex: String) {
        transport.send(.identityReceived(address: address, identityHex: identityHex))
    }
    public func radioAddressChanged(old: String, new: String, identityHash: String) {
        transport.send(.addressChanged(old: old, new: new, identityHash: identityHash))
    }
    public func radioError(severity: String, message: String) {
        transport.send(.error(severity: severity, message: message))
    }
}
