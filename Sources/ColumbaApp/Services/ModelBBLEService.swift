//
//  ModelBBLEService.swift
//  ColumbaApp
//
//  App side of the Model B BLE seam. CoreBluetooth can't run in the Network
//  Extension, so the app owns the REAL CoreBluetooth radio here: `SwiftBLEBridge`
//  (the same singleton the shipping Python path uses, so there is exactly one
//  radio per process). This service wraps `SwiftBLEBridge.shared` as a
//  `BleRadioDriver` and hands it to an `AppGroupBLEServer` that relays the NE's
//  `columba_ble_*` commands to the radio and the radio's events back over the
//  App-Group seam.
//
//  The driver-level abstraction itself lives in Python (`IOSBLEDriver`, the
//  Android-parity `BLEDriverInterface`); nothing here imports reticulum-swift.
//

import Foundation
import SwiftBLEBridge

/// Wraps `SwiftBLEBridge.shared` as the seam's `BleRadioDriver`. A nested
/// `BleCallbackInvoker` forwards the bridge's `BleCallbackSlot` invocations to a
/// `BleEventSink` (the `AppGroupBLEServer`). Argument shapes match the bridge's
/// `callbackInvoker?.invoke(slot:args:)` call sites.
final class SwiftBLEBridgeRadioDriver: BleRadioDriver, @unchecked Sendable {

    private final class Invoker: BleCallbackInvoker, @unchecked Sendable {
        weak var sink: BleEventSink?
        func invoke(slot: BleCallbackSlot, args: [Any]) {
            guard let sink else { return }
            let str: (Any?) -> String = { v in
                switch v { case let s as String: return s; case let n as NSNumber: return n.stringValue; default: return "" }
            }
            let int: (Any?) -> Int = { v in
                switch v { case let n as Int: return n; case let n as NSNumber: return n.intValue; default: return 0 }
            }
            switch slot {
            case .onDeviceDiscovered:
                // [address, name, rssi, serviceUUIDs]
                sink.radioDeviceDiscovered(address: str(args.first(where: { $0 is String })),
                                           name: args.count > 1 ? str(args[1]) : "",
                                           rssi: args.count > 2 ? Int16(clamping: int(args[2])) : 0)
            case .onDeviceConnected:
                sink.radioDeviceConnected(address: str(args.first(where: { $0 is String })),
                                          peerIdentity: args.count > 1 ? (args[1] as? Data) : nil)
            case .onDeviceDisconnected:
                sink.radioDeviceDisconnected(address: str(args.first(where: { $0 is String })))
            case .onDataReceived:
                sink.radioDataReceived(address: str(args.first(where: { $0 is String })),
                                       data: args.count > 1 ? (args[1] as? Data ?? Data()) : Data())
            case .onMtuNegotiated:
                sink.radioMtuNegotiated(address: str(args.first(where: { $0 is String })),
                                        mtu: args.count > 1 ? UInt16(clamping: int(args[1])) : 0)
            case .onIdentityReceived:
                sink.radioIdentityReceived(address: str(args.first(where: { $0 is String })),
                                           identityHex: args.count > 1 ? str(args[1]) : "")
            case .onAddressChanged:
                sink.radioAddressChanged(old: str(args.first(where: { $0 is String })),
                                         new: args.count > 1 ? str(args[1]) : "",
                                         identityHash: args.count > 2 ? str(args[2]) : "")
            case .onError:
                sink.radioError(severity: str(args.first(where: { $0 is String })),
                                message: args.count > 1 ? str(args[1]) : "")
            case .onDuplicateIdentityDetected:
                break  // see invokeBool
            }
        }
        // Synchronous duplicate-identity check: not round-tripped across the
        // process boundary (would block the app's BLE serial queue). Return
        // false so the app always accepts; the Python driver resolves rotation
        // via the async on_address_changed path.
        func invokeBool(slot: BleCallbackSlot, args: [Any]) -> Bool { return false }
    }

    private let invoker = Invoker()

    func setEventSink(_ sink: BleEventSink?) {
        invoker.sink = sink
        SwiftBLEBridge.shared.setCallbackInvoker(sink != nil ? invoker : nil)
    }

    func radioStart(serviceUuid: String, rxCharUuid: String, txCharUuid: String, identityCharUuid: String) {
        SwiftBLEBridge.shared.start(serviceUuid: serviceUuid, rxCharUuid: rxCharUuid, txCharUuid: txCharUuid, identityCharUuid: identityCharUuid)
    }
    func radioStop() { SwiftBLEBridge.shared.stop() }
    func radioSetIdentity(_ identity: Data) { SwiftBLEBridge.shared.setIdentity(identity) }
    func radioStartScanning() { SwiftBLEBridge.shared.startScanning() }
    func radioStopScanning() { SwiftBLEBridge.shared.stopScanning() }
    func radioStartAdvertising(deviceName: String?, identity: Data) {
        if !identity.isEmpty { SwiftBLEBridge.shared.setIdentity(identity) }
        SwiftBLEBridge.shared.startAdvertising(deviceName: deviceName)
    }
    func radioStopAdvertising() { SwiftBLEBridge.shared.stopAdvertising() }
    func radioConnect(address: String) { SwiftBLEBridge.shared.connect(address: address) }
    func radioDisconnect(address: String) { SwiftBLEBridge.shared.disconnect(address: address) }
    func radioSend(address: String, data: Data) { _ = SwiftBLEBridge.shared.send(address: address, data: data) }
    func radioSyncExistingConnections() { SwiftBLEBridge.shared.syncExistingConnections() }
    func radioRequestIdentityResync(address: String) { _ = SwiftBLEBridge.shared.requestIdentityResync(address: address) }
}

public final class ModelBBLEService: @unchecked Sendable {

    public static let shared = ModelBBLEService()

    /// True when the BLE host should start: an enabled `.ble` interface exists in
    /// the repository. Gated on the interface list (not a standalone consent flag);
    /// the interface is created via Manage Interfaces (or onboarding in shipping
    /// builds where BLE is selectable). `repo` is injectable for tests.
    static func shouldStart(repo: InterfaceRepository = InterfaceRepository()) -> Bool {
        hasEnabledBLEInterface(repo: repo)
    }

    /// True when any enabled interface in the repository is a BLE interface.
    static func hasEnabledBLEInterface(repo: InterfaceRepository = InterfaceRepository()) -> Bool {
        repo.getEnabledInterfaces().contains { $0.type == .ble }
    }

    private init() {}

    private let lock = NSLock()
    private var transport: AppGroupBLESeamTransport?
    private var server: AppGroupBLEServer?

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return server != nil }

    /// Construct + start the CoreBluetooth relay. Idempotent. The radio
    /// (`SwiftBLEBridge.shared`) is started by the NE's first `columba_ble_start`
    /// command (the Python driver issues it during `BLEInterface.start()`), so
    /// this side only brings up the seam + event routing — it does not
    /// pre-start the CB managers.
    /// - Parameter identityHash: the 16-byte transport identity. Stashed and
    ///   pre-applied so the GATT identity characteristic matches even before the
    ///   NE's first command arrives.
    public func start(identityHash: Data) {
        lock.lock(); defer { lock.unlock() }
        guard server == nil else { return }
        precondition(identityHash.count == 16, "BLE transport identity must be 16 bytes")

        let tx = AppGroupBLESeamTransport(role: .app)
        let driver = SwiftBLEBridgeRadioDriver()
        let srv = AppGroupBLEServer(transport: tx, driver: driver, log: { DiagLog.log($0) })
        srv.start()
        // Pre-apply the transport identity so the GATT identity characteristic is
        // correct from the first advertisement.
        driver.radioSetIdentity(identityHash)

        self.transport = tx
        self.server = srv
        DiagLog.log("[BLE] Model B BLE service started (SwiftBLEBridge relay + AppGroupBLEServer)")
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        server?.stop()
        server = nil
        transport = nil
        DiagLog.log("[BLE] Model B BLE service stopped")
    }
}
