//
//  SwiftRNodeBridge.swift
//  SwiftBLEBridge
//
//  CoreBluetooth Nordic-UART-Service (NUS) client for RNode LoRa hardware.
//
//  Deliberately SEPARATE from `SwiftBLEBridge`: the RNode interface and the BLE
//  mesh are unrelated transports that can be enabled independently or at the
//  same time, so each owns its own `CBCentralManager` + delegate (decision:
//  Torlando, 2026-05-26 — no shared scanner, no coupling). They merely share
//  this SwiftPM module because both are pure-CoreBluetooth code; there is no
//  runtime coupling between the two centrals.
//
//  This is the Swift (I/O) half of the iOS RNode interface. The KISS framing +
//  RNode binary protocol live in Python (`app/rnode/IOSRNodeInterface.py`,
//  ported from Android). Python → Swift goes through the `columba_rnode_*`
//  C-ABI shims in `RNodeNativeBindings.swift`; Swift → Python goes through the
//  injected `RNodeCallbackInvoker` (concrete impl `PythonRNodeCallbackBridge`,
//  which lives in the pbxproj target because it needs Python.h). Mirrors the
//  IOSBLEInterface / SwiftBLEBridge split exactly.
//
//  BLE/NUS only — no USB-serial, no Bluetooth Classic (no iOS support).
//

import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// Callback slots the Python RNode interface registers with the bridge via
/// `rns_bridge.set_rnode_callback(slot, callable)`. Scoped to the two events a
/// NUS client emits (cf. the richer `BleCallbackSlot` for the mesh).
public enum RNodeCallbackSlot: String, Sendable, CaseIterable {
    /// `cb(data: bytes)` — a payload notified on the NUS TX characteristic
    /// (RNode → phone). Raw serial bytes; the Python side runs KISS framing.
    case onData = "data"
    /// `cb(connected: bool, device_name: str)` — link came up (TX notify
    /// subscribed) or went down (disconnect).
    case onState = "state"
}

/// Abstraction over "invoke the Python RNode callback registered under this
/// slot". Concrete impl (`PythonRNodeCallbackBridge`) is pbxproj-only (needs
/// Python.h); the SwiftPM target builds + unit-tests without the Python C-API
/// by injecting a stub. Mirror of `BleCallbackInvoker`, minus the bool-return
/// variant (RNode has no synchronous callbacks).
public protocol RNodeCallbackInvoker: AnyObject, Sendable {
    func invoke(slot: RNodeCallbackSlot, args: [Any])
}

#if canImport(CoreBluetooth)

/// CoreBluetooth NUS client. Scans for the RNode by advertised name, connects,
/// discovers the Nordic UART Service, subscribes to TX notifications, and
/// writes outbound serial to RX (write-without-response, MTU-chunked). One per
/// process — the `@_cdecl` shims route through `.shared`.
public final class SwiftRNodeBridge: NSObject, @unchecked Sendable {

    public static let shared = SwiftRNodeBridge()

    // Nordic UART Service — RNode firmware exposes its BLE serial here.
    private static let nusService = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    private static let nusRxChar  = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e") // write  (phone → RNode)
    private static let nusTxChar  = CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e") // notify (RNode → phone)

    /// Own serial queue — distinct from SwiftBLEBridge's. CB delegate callbacks
    /// land here; callback invocations hop to the Python serial queue inside
    /// PythonBridge.
    private let queue = DispatchQueue(label: "network.columba.rnode", qos: .userInitiated)
    private var callbackInvoker: RNodeCallbackInvoker?

    // Our own central — NOT shared with the mesh. Held strong for the bridge's
    // lifetime; reused across stop()/start() to avoid CB teardown races.
    private var central: CBCentralManager?
    // Strong ref to the connected peripheral — iOS deallocates CBPeripheral
    // without one, dropping the link. Also the handle for background reconnect.
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?

    private var targetName: String = ""   // device name to match while scanning
    private var wantConnected = false     // user intends a live link → drives reconnect
    private var isLinkUp = false          // TX notify subscribed → link usable
    private var startedFlag = false

    // Writes issued before the link is up (the protocol sends radio config
    // right after connect(), but our connect is async). Queued here and flushed
    // on link-up so radio config isn't silently lost into a not-yet-ready link.
    private var pendingWrites: [Data] = []
    private let maxPendingWrites = 128

    public override init() { super.init() }

    // MARK: - Public API (called from the C-ABI shims / app glue)

    public func setCallbackInvoker(_ invoker: RNodeCallbackInvoker?) {
        queue.sync { self.callbackInvoker = invoker }
    }

    /// Bring up the central. Idempotent. The central isn't created until here,
    /// so merely installing the callback invoker at app launch costs nothing.
    public func start() {
        queue.sync {
            guard !startedFlag else { return }
            if central == nil {
                central = CBCentralManager(delegate: self, queue: queue)
            }
            startedFlag = true
        }
    }

    /// Tear down the active link but keep the central alive (Apply & Restart
    /// calls stop() then start() in quick succession). Clears reconnect intent.
    public func stop() {
        queue.sync {
            wantConnected = false
            if let c = central, c.isScanning { c.stopScan() }
            if let p = peripheral { central?.cancelPeripheralConnection(p) }
            teardownLinkLocked(notify: false)
            peripheral = nil
        }
    }

    /// Connect to the RNode advertising `deviceName`. If we already hold the
    /// peripheral (reconnect after a drop), issue a direct pending connect
    /// (works in the background, no scan); otherwise start scanning.
    public func connect(deviceName: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.targetName = deviceName
            self.wantConnected = true
            if let p = self.peripheral {
                self.central?.connect(p, options: nil)
                self.log("reconnect-issued name=\(deviceName)")
            } else {
                self.tryStartScanLocked()
            }
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantConnected = false
            if let c = self.central, c.isScanning { c.stopScan() }
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.teardownLinkLocked(notify: true)
            self.peripheral = nil
        }
    }

    /// Write outbound serial to the RNode RX characteristic, chunked to the
    /// negotiated write-without-response MTU. KISS frames routinely exceed one
    /// BLE MTU; the RNode firmware reassembles a continuous serial stream, so
    /// sequential chunking with no inter-chunk framing is correct.
    public func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isLinkUp, self.peripheral != nil, self.rxChar != nil else {
                // Link not up yet — queue (bounded) and flush on link-up.
                if self.pendingWrites.count < self.maxPendingWrites {
                    self.pendingWrites.append(data)
                } else {
                    self.log("pending-write queue full — dropping \(data.count)B")
                }
                return
            }
            self.writeChunkedLocked(data)
        }
    }

    /// Chunk + write to the RX characteristic. Caller guarantees the link is up.
    private func writeChunkedLocked(_ data: Data) {
        guard let p = peripheral, let rx = rxChar else { return }
        let mtu = max(20, p.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < data.count {
            let end = min(offset + mtu, data.count)
            p.writeValue(data.subdata(in: offset..<end), for: rx, type: .withoutResponse)
            offset = end
        }
    }

    private func flushPendingWritesLocked() {
        guard !pendingWrites.isEmpty else { return }
        log("flushing \(pendingWrites.count) queued write(s) on link-up")
        let queued = pendingWrites
        pendingWrites.removeAll()
        for d in queued { writeChunkedLocked(d) }
    }

    // MARK: - Private helpers (all called with `queue` held / on `queue`)

    private func tryStartScanLocked() {
        guard let c = central, c.state == .poweredOn else { return } // resumes in didUpdateState
        if c.isScanning { return }
        // nil service filter: RNode advertisements frequently omit the NUS UUID
        // (firmware advertises only the device name), so we match on name in
        // didDiscover. Background reconnect doesn't rely on this — it uses the
        // cached peripheral via connect(), which needs no scan.
        c.scanForPeripherals(withServices: nil, options: nil)
        log("scan-started target='\(targetName)'")
    }

    private func nameMatches(_ adName: String?) -> Bool {
        guard !targetName.isEmpty else { return true } // empty → first NUS device seen
        let t = targetName.lowercased()
        guard let n = adName?.lowercased() else { return false }
        return n == t || n.contains(t)
    }

    private func teardownLinkLocked(notify: Bool) {
        rxChar = nil
        txChar = nil
        // Drop queued writes — on reconnect the protocol re-runs _configure_device
        // and re-sends radio config, so stale queued frames must not replay.
        pendingWrites.removeAll()
        let wasUp = isLinkUp
        isLinkUp = false
        if notify && wasUp {
            callbackInvoker?.invoke(slot: .onState, args: [false, targetName])
        }
    }

    fileprivate func log(_ message: String) {
        print("SwiftRNodeBridge: \(message)")
    }
}

// MARK: - CBCentralManagerDelegate

extension SwiftRNodeBridge: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("central poweredOn")
            // Resume whatever the user asked for before the radio was ready.
            if wantConnected {
                if let p = peripheral { central.connect(p, options: nil) }
                else { tryStartScanLocked() }
            }
        case .unauthorized: log("unauthorized — check Bluetooth permission")
        case .poweredOff:   log("poweredOff")
        case .unsupported:  log("unsupported on this device")
        case .resetting:    log("resetting")
        case .unknown:      log("state unknown")
        @unknown default:   log("state \(central.state.rawValue)")
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let adName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard nameMatches(adName) else { return }
        log("matched '\(adName ?? "")' rssi=\(RSSI.intValue) — connecting")
        central.stopScan()
        self.peripheral = peripheral          // strong ref before connect
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("didConnect — discovering NUS")
        peripheral.discoverServices([Self.nusService])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        log("didFailToConnect: \(String(describing: error))")
        // Direct connect failed (e.g. out of range) — fall back to scanning.
        if wantConnected { tryStartScanLocked() }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        log("didDisconnect: \(String(describing: error))")
        teardownLinkLocked(notify: true)
        // Auto-reconnect: RNode BLE links drop often. If the user still wants
        // the link, issue a direct pending connect to the same peripheral; CB
        // completes it (even backgrounded) when the RNode is back in range.
        if wantConnected, let p = self.peripheral {
            central.connect(p, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension SwiftRNodeBridge: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("didDiscoverServices error: \(error)"); return }
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.nusService }) else {
            log("NUS service not found")
            return
        }
        peripheral.discoverCharacteristics([Self.nusRxChar, Self.nusTxChar], for: svc)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error { log("didDiscoverCharacteristics error: \(error)"); return }
        for ch in (service.characteristics ?? []) {
            switch ch.uuid {
            case Self.nusRxChar: rxChar = ch
            case Self.nusTxChar: txChar = ch
            default: break
            }
        }
        guard let tx = txChar, rxChar != nil else {
            log("NUS RX/TX characteristic missing")
            return
        }
        // Link comes up once the TX subscription is confirmed
        // (didUpdateNotificationStateFor).
        peripheral.setNotifyValue(true, for: tx)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error { log("didUpdateNotificationState error: \(error)"); return }
        guard characteristic.uuid == Self.nusTxChar, characteristic.isNotifying else { return }
        isLinkUp = true
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        log("link up — TX notify subscribed, mtu=\(mtu)")
        callbackInvoker?.invoke(slot: .onState, args: [true, targetName])
        flushPendingWritesLocked()
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error { log("didUpdateValueFor error: \(error)"); return }
        guard characteristic.uuid == Self.nusTxChar,
              let value = characteristic.value, !value.isEmpty else { return }
        callbackInvoker?.invoke(slot: .onData, args: [value])
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error { log("didWriteValueFor error: \(error)") }
    }
}

#else

/// Non-CoreBluetooth stub so `swift build` typechecks the module on Linux/CI.
/// Mirrors the real bridge's surface (cf. the SwiftBLEBridge stub).
public final class SwiftRNodeBridge: @unchecked Sendable {
    public static let shared = SwiftRNodeBridge()
    public func setCallbackInvoker(_ invoker: RNodeCallbackInvoker?) {}
    public func start() {}
    public func stop() {}
    public func connect(deviceName: String) {}
    public func disconnect() {}
    public func write(_ data: Data) {}
}

#endif
