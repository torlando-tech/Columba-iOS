//
//  SwiftBLEBridge.swift
//  SwiftBLEBridge
//
//  Entry point that the iOS Python driver (`app/ble/IOSBLEDriver.py`) calls
//  into via ctypes-bound C-ABI shims in `BleNativeBindings.swift`. The bridge
//  owns the process-wide `CBCentralManager` + `CBPeripheralManager` pair,
//  routes CoreBluetooth delegate callbacks back to Python via the registered
//  `BleCallbackInvoker`, and tracks per-peer connection state.
//
//  Phase 4 — scan + advertise implemented end-to-end. Phases 5-6 add
//  central-mode connection + GATT and peripheral-mode GATT server.
//

import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// Callback slots the Python driver registers with the bridge. The names
/// match the kwargs passed up to BLEInterface (`on_device_discovered`,
/// `on_device_connected`, etc.) so the routing layer can do a string lookup.
public enum BleCallbackSlot: String, Sendable, CaseIterable {
    case onDeviceDiscovered = "on_device_discovered"
    case onDeviceConnected = "on_device_connected"
    case onDeviceDisconnected = "on_device_disconnected"
    case onDataReceived = "on_data_received"
    case onMtuNegotiated = "on_mtu_negotiated"
    case onIdentityReceived = "on_identity_received"
    case onAddressChanged = "on_address_changed"
    case onDuplicateIdentityDetected = "on_duplicate_identity_detected"
    case onError = "on_error"
}

/// Abstraction over "invoke a Python callback registered under this slot".
/// The concrete implementation lives in `PythonBLECallbackBridge.swift` (pbxproj-only,
/// has access to Python.h); the SwiftPM target can be built and unit-tested
/// without the Python C-API by injecting a test stub.
public protocol BleCallbackInvoker: AnyObject, Sendable {
    func invoke(slot: BleCallbackSlot, args: [Any])
    func invokeBool(slot: BleCallbackSlot, args: [Any]) -> Bool
}

#if canImport(CoreBluetooth)

/// Main bridge object. Mirror of Android's `KotlinBLEBridge.kt`, scoped down
/// to what iOS / CoreBluetooth actually surface.
public final class SwiftBLEBridge: NSObject, @unchecked Sendable {

    /// Process-wide singleton — the `@_cdecl` C-ABI shims in
    /// `BleNativeBindings.swift` (invoked from Python via ctypes) route
    /// through here. One bridge per app is sufficient since CoreBluetooth
    /// itself is process-wide.
    public static let shared = SwiftBLEBridge()

    // MARK: - State

    internal let queue = DispatchQueue(label: "network.columba.ble", qos: .userInitiated)
    private var callbackInvoker: BleCallbackInvoker?
    private var isStartedFlag: Bool = false
    private var localIdentity: Data = Data()
    private var powerSettings: BlePowerSettings = BlePowerSettings()

    // CB managers — lazily instantiated in `start(...)`. Held by strong refs
    // for the lifetime of the bridge.
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?

    // RSSI throttling for didDiscover. Per-peer "last reported" so we
    // don't flood the Python callback path. Matches Android's pattern.
    private var lastDiscoveryReport: [String: (rssi: Int, time: Date)] = [:]
    private let rssiDeltaThreshold: Int = 5
    private let rssiThrottleInterval: TimeInterval = 1.0

    // Pending operations: requested before CB managers reach .poweredOn.
    // Drained in centralManager(_:didUpdate:) / peripheralManager(_:didUpdate:).
    private var pendingScanRequested: Bool = false
    private var pendingAdvertiseRequested: Bool = false
    private var pendingAdvertiseDeviceName: String?

    // Per-peer GATT client state for centrals (peripherals we connected TO).
    // Strong refs to CBPeripheral live here — iOS deallocates peripherals
    // without strong refs, dropping the connection.
    private var gattClients: [String: BleGattClient] = [:]

    // RSSI poll cadence for established central-side connections. Reads
    // are async (via didReadRSSI callback) so we just kick a `readRSSI()`
    // periodically and the result lands on the client.
    private var rssiPollTask: Task<Void, Never>?
    private let rssiPollInterval: TimeInterval = 3.0

    // Discovered peripherals from scan, retained by `identifier.uuidString`.
    // `connect(address:)` looks them up here.
    private var discoveredPeripherals: [String: CBPeripheral] = [:]

    // Per-subscriber state for peripheral-mode (centrals connected TO us).
    // Keyed by `CBCentral.identifier.uuidString`.
    private var gattServerPeers: [String: BleGattServerPeer] = [:]

    // Cap on a peer's backpressure notify queue (mirrors
    // SwiftRNodeBridge.maxPendingWrites) so a stuck or vanished subscriber
    // can't grow pendingNotifies without bound.
    private let maxPendingNotifies = 128

    // Mutable characteristics published by our peripheral-mode GATT server.
    // Set once during start(); never re-added (iOS broadcasts Service Changed
    // on re-add which can break subscribed centrals).
    private var serverRxChar: CBMutableCharacteristic?
    private var serverTxChar: CBMutableCharacteristic?
    private var serverIdentityChar: CBMutableCharacteristic?
    private var gattServiceAdded: Bool = false

    // MARK: - Service UUIDs (set in start; injected by Python driver)

    private var serviceCBUUID: CBUUID = BleConstants.serviceCBUUID
    private var rxCharCBUUID: CBUUID = BleConstants.rxCharCBUUID
    private var txCharCBUUID: CBUUID = BleConstants.txCharCBUUID
    private var identityCharCBUUID: CBUUID = BleConstants.identityCharCBUUID

    public override init() { super.init() }

    // MARK: - Public API

    public var isStarted: Bool {
        queue.sync { isStartedFlag }
    }

    public func setCallbackInvoker(_ invoker: BleCallbackInvoker?) {
        queue.sync {
            self.callbackInvoker = invoker
        }
    }

    public func setIdentity(_ identity: Data) {
        queue.sync {
            localIdentity = identity
        }
    }

    public func configurePower(_ settings: BlePowerSettings) {
        queue.sync { powerSettings = settings }
    }

    /// Bring up the CB managers. Safe to call multiple times — subsequent
    /// calls are no-ops once `isStartedFlag` is true.
    public func start(
        serviceUuid: String,
        rxCharUuid: String,
        txCharUuid: String,
        identityCharUuid: String
    ) {
        queue.sync {
            guard !isStartedFlag else { return }
            self.serviceCBUUID = CBUUID(string: serviceUuid)
            self.rxCharCBUUID = CBUUID(string: rxCharUuid)
            self.txCharCBUUID = CBUUID(string: txCharUuid)
            self.identityCharCBUUID = CBUUID(string: identityCharUuid)
            // Central + peripheral managers share our BLE serial queue —
            // delegate callbacks land on this queue, callback invocations
            // hop back to the Python serial queue inside PythonBridge.
            //
            // Reuse existing managers when they exist (Apply & Restart
            // calls stop() then start() in quick succession; stop() now
            // intentionally leaves the managers alive to avoid CB
            // teardown races). Only create on first start.
            if self.centralManager == nil {
                self.centralManager = CBCentralManager(delegate: self, queue: queue)
            }
            if self.peripheralManager == nil {
                self.peripheralManager = CBPeripheralManager(delegate: self, queue: queue)
            }
            self.isStartedFlag = true
            // Surface any already-poweredOn managers so scan/advertise
            // requests don't sit pending forever after a restart.
            if self.centralManager?.state == .poweredOn {
                tryStartScanLocked()
            }
            if self.peripheralManager?.state == .poweredOn {
                setUpGattServiceIfNeeded()
                tryStartAdvertiseLocked()
            }
        }
        startRssiPolling()
    }

    /// Periodically request RSSI samples from connected centrals so the
    /// BLE Connections UI can show a current-ish dBm reading instead of
    /// the (often stale) scan-time RSSI. Results land asynchronously via
    /// `peripheral(_:didReadRSSI:error:)` and get stored on the
    /// `BleGattClient`.
    private func startRssiPolling() {
        rssiPollTask?.cancel()
        rssiPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.rssiPollInterval ?? 3.0) * 1_000_000_000))
                guard let self else { return }
                self.queue.async {
                    for (_, client) in self.gattClients
                        where client.state == .established
                            && client.peripheral.state == .connected {
                        client.peripheral.readRSSI()
                    }
                }
            }
        }
    }

    public func stop() {
        rssiPollTask?.cancel()
        rssiPollTask = nil
        queue.sync {
            guard isStartedFlag else { return }
            if let cm = centralManager, cm.isScanning { cm.stopScan() }
            if let pm = peripheralManager {
                if pm.isAdvertising { pm.stopAdvertising() }
                pm.removeAllServices()
            }
            // Tear down all open connections.
            for (_, client) in gattClients {
                centralManager?.cancelPeripheralConnection(client.peripheral)
            }
            gattClients.removeAll()
            discoveredPeripherals.removeAll()
            gattServerPeers.removeAll()
            serverRxChar = nil
            serverTxChar = nil
            serverIdentityChar = nil
            gattServiceAdded = false
            lastDiscoveryReport.removeAll()
            pendingScanRequested = false
            pendingAdvertiseRequested = false
            pendingAdvertiseDeviceName = nil
            isStartedFlag = false
            // NOTE: do NOT null out centralManager / peripheralManager
            // here. Tying their lifetime to the bridge singleton lets
            // start() be called repeatedly without churning CB internals.
            // Apple's CB stack crashes (watchdog-kills the app via
            // exit-code-65280 abort path) if a new CBCentralManager /
            // CBPeripheralManager is created while the previous instance
            // is still in mid-teardown — the symptom we hit on
            // Apply & Restart when stop() was followed milliseconds
            // later by another start().
        }
    }

    /// Build + register the GATT service exactly once. Called from
    /// `peripheralManagerDidUpdateState(.poweredOn)`. Re-adding the service
    /// at runtime causes iOS to broadcast Service Changed which can break
    /// subscribed centrals, so we guard against re-add with `gattServiceAdded`.
    fileprivate func setUpGattServiceIfNeeded() {
        guard let pm = peripheralManager,
              pm.state == .poweredOn,
              !gattServiceAdded else { return }

        let rx = CBMutableCharacteristic(
            type: rxCharCBUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let tx = CBMutableCharacteristic(
            type: txCharCBUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        // Identity is published with the current localIdentity bytes (set
        // via setIdentity before start). A static-value characteristic
        // returns the bytes for any read; if localIdentity is empty we
        // initialise empty and respond dynamically on read instead.
        let identityValue: Data? = localIdentity.isEmpty ? nil : localIdentity
        let identity = CBMutableCharacteristic(
            type: identityCharCBUUID,
            properties: [.read],
            value: identityValue,
            permissions: [.readable]
        )

        let service = CBMutableService(type: serviceCBUUID, primary: true)
        service.characteristics = [rx, tx, identity]
        pm.add(service)

        serverRxChar = rx
        serverTxChar = tx
        serverIdentityChar = identity
        gattServiceAdded = true
        emitInfo("gatt-service-added serviceUuid=\(serviceCBUUID.uuidString)")
    }

    // MARK: - Scan + advertise

    public func startScanning() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingScanRequested = true
            self.tryStartScanLocked()
        }
    }

    public func stopScanning() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingScanRequested = false
            if let cm = self.centralManager, cm.isScanning {
                cm.stopScan()
            }
        }
    }

    public func startAdvertising(deviceName: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingAdvertiseRequested = true
            self.pendingAdvertiseDeviceName = deviceName
            self.tryStartAdvertiseLocked()
        }
    }

    public func stopAdvertising() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingAdvertiseRequested = false
            if let pm = self.peripheralManager, pm.isAdvertising {
                pm.stopAdvertising()
            }
        }
    }

    // MARK: - Connection management

    public func connect(address: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let cm = self.centralManager else { return }
            // Resolve the CBPeripheral by address. Prefer the cached
            // discovered one (active scan), fall back to retrieve-known
            // (post-restart). If still nil we can't connect.
            let peripheral: CBPeripheral?
            if let cached = self.discoveredPeripherals[address] {
                peripheral = cached
            } else if let uuid = UUID(uuidString: address) {
                let known = cm.retrievePeripherals(withIdentifiers: [uuid])
                peripheral = known.first
            } else {
                peripheral = nil
            }
            guard let peripheral else {
                self.emitError("warning", "connect: unknown address \(address)")
                return
            }
            peripheral.delegate = self
            // Hold strong ref — iOS deallocates CBPeripheral without one.
            let client = self.gattClients[address] ?? BleGattClient(peripheral: peripheral)
            client.state = .connecting
            self.gattClients[address] = client
            cm.connect(peripheral, options: nil)
            self.emitInfo("connect-issued addr=\(address)")
        }
    }

    public func disconnect(address: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let cm = self.centralManager,
                  let client = self.gattClients[address] else { return }
            cm.cancelPeripheralConnection(client.peripheral)
        }
    }

    public func send(address: String, data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            // Central role: write to peer's RX char without response.
            if let client = self.gattClients[address], let rxChar = client.rxChar {
                client.peripheral.writeValue(data, for: rxChar, type: .withoutResponse)
                return
            }
            // Peripheral role: notify on TX char to the specific subscriber.
            if let peer = self.gattServerPeers[address],
               let txChar = self.serverTxChar,
               let pm = self.peripheralManager {
                let ok = pm.updateValue(data, for: txChar, onSubscribedCentrals: [peer.central])
                if !ok {
                    // Backpressure — queue and drain on peripheralManagerIsReady.
                    // Bounded so a stuck/vanished subscriber can't grow it
                    // unbounded; drop the frame (and warn) when full.
                    if peer.pendingNotifies.count < maxPendingNotifies {
                        peer.pendingNotifies.append(data)
                    } else {
                        emitError("warning", "pendingNotifies full (\(maxPendingNotifies)) for \(address); dropping frame")
                    }
                }
                return
            }
            self.emitError("warning", "send: no client / no server peer for \(address)")
        }
    }

    // MARK: - Queries

    public func getConnectedPeers() -> [String] {
        queue.sync {
            var peers: [String] = []
            peers.append(contentsOf: gattClients
                .filter { $0.value.state == .established }
                .map { $0.key })
            peers.append(contentsOf: gattServerPeers
                .filter { $0.value.state == .established }
                .map { $0.key })
            return peers
        }
    }

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    public func getPeerIdentity(address: String) -> String? {
        queue.sync {
            if let c = gattClients[address], let id = c.peerIdentity { return hex(id) }
            if let s = gattServerPeers[address], let id = s.identity { return hex(id) }
            return nil
        }
    }
    public func getPeerAddress(identityHashHex: String) -> String? {
        queue.sync {
            for (addr, client) in gattClients {
                if let id = client.peerIdentity, hex(id) == identityHashHex { return addr }
            }
            for (addr, peer) in gattServerPeers {
                if let id = peer.identity, hex(id) == identityHashHex { return addr }
            }
            return nil
        }
    }
    public func getPeerRssi(address: String) -> Int? {
        queue.sync { lastDiscoveryReport[address]?.rssi }
    }
    public func getConnectionDetails() -> [BleConnectionDetails] {
        queue.sync {
            var details: [BleConnectionDetails] = []
            for (addr, client) in gattClients {
                // Prefer the fresh `readRSSI()` sample if we have one;
                // fall back to the last scan-time RSSI from discovery.
                let rssi = client.rssi ?? lastDiscoveryReport[addr]?.rssi
                details.append(BleConnectionDetails(
                    address: addr,
                    identityHashHex: client.peerIdentity.map { hex($0) },
                    role: .central,
                    mtu: client.mtu,
                    rssi: rssi,
                    lastActivity: lastDiscoveryReport[addr]?.time ?? client.connectedAt,
                    connectedAt: client.connectedAt
                ))
            }
            for (addr, peer) in gattServerPeers {
                details.append(BleConnectionDetails(
                    address: addr,
                    identityHashHex: peer.identity.map { hex($0) },
                    role: .peripheral,
                    mtu: peer.mtu,
                    rssi: nil, // CB doesn't expose central-side RSSI to peripherals
                    lastActivity: peer.connectedAt,
                    connectedAt: peer.connectedAt
                ))
            }
            return details
        }
    }

    // MARK: - Private helpers (all called with `queue` held)

    fileprivate func tryStartScanLocked() {
        guard pendingScanRequested,
              let cm = centralManager,
              cm.state == .poweredOn else { return }
        if cm.isScanning { return }
        // Allowing duplicates so we get continuous RSSI updates from the
        // same peer; throttling happens in didDiscover.
        cm.scanForPeripherals(
            withServices: [serviceCBUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        emitInfo("scan-started serviceUuid=\(serviceCBUUID.uuidString)")
    }

    fileprivate func tryStartAdvertiseLocked() {
        guard pendingAdvertiseRequested,
              let pm = peripheralManager,
              pm.state == .poweredOn else { return }
        if pm.isAdvertising { pm.stopAdvertising() }
        var ad: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceCBUUID]
        ]
        // iOS drops the local-name field when the app is backgrounded but
        // keeps the service UUID in the overflow area. We set it for the
        // foreground case so peer settings UIs can render a readable name.
        if let name = pendingAdvertiseDeviceName, !name.isEmpty {
            ad[CBAdvertisementDataLocalNameKey] = name
        }
        pm.startAdvertising(ad)
        emitInfo("advertise-started name=\(pendingAdvertiseDeviceName ?? "<nil>")")
    }

    fileprivate func emitInfo(_ message: String) {
        callbackInvoker?.invoke(slot: .onError, args: ["info", message])
    }

    fileprivate func emitError(_ severity: String, _ message: String) {
        callbackInvoker?.invoke(slot: .onError, args: [severity, message])
    }
}

// MARK: - CBCentralManagerDelegate

extension SwiftBLEBridge: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            emitInfo("centralManager poweredOn")
            tryStartScanLocked()
        case .poweredOff:
            emitError("warning", "centralManager poweredOff")
        case .unauthorized:
            emitError("critical", "centralManager unauthorized — check Bluetooth permission")
        case .unsupported:
            emitError("critical", "centralManager unsupported on this device")
        case .resetting:
            emitError("warning", "centralManager resetting")
        case .unknown:
            emitInfo("centralManager state unknown")
        @unknown default:
            emitInfo("centralManager state \(central.state.rawValue)")
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let address = peripheral.identifier.uuidString
        let rssi = RSSI.intValue
        // Skip sentinel RSSIs (CB occasionally hands us 127 or -127 for
        // out-of-range / invalid samples).
        guard rssi != 127, rssi != -127, rssi != 0 else { return }

        // Cache the peripheral so `connect(address:)` can find it. iOS
        // deallocates peripherals without strong refs, so this is required.
        discoveredPeripherals[address] = peripheral

        // RSSI throttle: drop if same peer reported < threshold dBm change
        // within the throttle interval. Matches Android's pattern.
        let now = Date()
        if let last = lastDiscoveryReport[address] {
            let dt = now.timeIntervalSince(last.time)
            if dt < rssiThrottleInterval && abs(rssi - last.rssi) < rssiDeltaThreshold {
                return
            }
        }
        lastDiscoveryReport[address] = (rssi, now)

        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString.lowercased() } ?? []

        callbackInvoker?.invoke(
            slot: .onDeviceDiscovered,
            args: [address, name, rssi, serviceUUIDs]
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        let address = peripheral.identifier.uuidString
        guard let client = gattClients[address] else {
            emitError("warning", "didConnect for unknown client \(address)")
            return
        }
        // iOS auto-negotiates MTU at connect time. Fire on_mtu_negotiated
        // immediately with the maximum the link supports. Use the
        // withoutResponse query — that's what we actually send with.
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        client.mtu = mtu
        if !client.mtuFired {
            client.mtuFired = true
            callbackInvoker?.invoke(slot: .onMtuNegotiated, args: [address, mtu])
        }
        client.state = .discoveringServices
        peripheral.discoverServices([serviceCBUUID])
        emitInfo("didConnect addr=\(address) mtu=\(mtu)")
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let address = peripheral.identifier.uuidString
        emitError("warning", "didFailToConnect addr=\(address) error=\(String(describing: error))")
        gattClients.removeValue(forKey: address)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let address = peripheral.identifier.uuidString
        gattClients.removeValue(forKey: address)
        callbackInvoker?.invoke(slot: .onDeviceDisconnected, args: [address])
    }
}

// MARK: - CBPeripheralDelegate (central-mode discovery + I/O)

extension SwiftBLEBridge: CBPeripheralDelegate {

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        let address = peripheral.identifier.uuidString
        if let error {
            emitError("warning", "didDiscoverServices error addr=\(address): \(error)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceCBUUID }) else {
            emitError("warning", "didDiscoverServices: target service not found on \(address)")
            return
        }
        gattClients[address]?.state = .discoveringChars
        peripheral.discoverCharacteristics(
            [rxCharCBUUID, txCharCBUUID, identityCharCBUUID],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let address = peripheral.identifier.uuidString
        if let error {
            emitError("warning", "didDiscoverCharacteristics error addr=\(address): \(error)")
            return
        }
        guard let client = gattClients[address] else { return }
        for ch in (service.characteristics ?? []) {
            switch ch.uuid {
            case rxCharCBUUID:       client.rxChar = ch
            case txCharCBUUID:       client.txChar = ch
            case identityCharCBUUID: client.identityChar = ch
            default: break
            }
        }
        guard client.rxChar != nil, let txChar = client.txChar,
              let identityChar = client.identityChar else {
            // Missing any of RX/TX/Identity means we'd fire onDeviceConnected
            // (after the identity read) but never be able to write our identity
            // or data back — a half-open link Python believes is up. Bail.
            emitError("warning", "didDiscoverCharacteristics: missing RX/TX/Identity for \(address)")
            return
        }
        client.state = .readingIdentity
        // Subscribe to notifications on TX so peer-sent fragments arrive
        // via `didUpdateValueFor`. Independently, kick off the Identity read.
        peripheral.setNotifyValue(true, for: txChar)
        peripheral.readValue(for: identityChar)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            emitError("warning", "didUpdateNotificationState error: \(error)")
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let address = peripheral.identifier.uuidString
        if let error {
            emitError("warning", "didUpdateValueFor error addr=\(address) uuid=\(characteristic.uuid): \(error)")
            return
        }
        guard let client = gattClients[address] else { return }
        guard let value = characteristic.value else { return }

        switch characteristic.uuid {
        case identityCharCBUUID:
            // Identity characteristic — 16-byte peer identity hash.
            guard value.count == BleConstants.identitySize else {
                emitError("warning", "identity char wrong size: \(value.count)")
                return
            }
            client.peerIdentity = value
            let identityHex = value.map { String(format: "%02x", $0) }.joined()
            callbackInvoker?.invoke(slot: .onIdentityReceived, args: [address, identityHex])

            // Synchronous duplicate-identity check. If Python says it's a
            // duplicate (same identity already alive at a different addr),
            // tear down this connection and bail.
            if let invoker = callbackInvoker {
                let isDup = invoker.invokeBool(
                    slot: .onDuplicateIdentityDetected,
                    args: [address, value]
                )
                if isDup {
                    emitInfo("duplicate identity at \(address); dropping")
                    centralManager?.cancelPeripheralConnection(peripheral)
                    return
                }
            }

            // Connection complete from upstream's perspective — fire connected
            // (with identity) so BLEInterface spawns the peer interface.
            if !client.connectedFired {
                client.connectedFired = true
                callbackInvoker?.invoke(slot: .onDeviceConnected, args: [address, value])
            }

            // Write our identity to the peer's RX char to complete the
            // handshake on their side. Use .withoutResponse for parity with
            // Android (no ACK needed; upstream interface handles retransmit).
            if let rxChar = client.rxChar, !localIdentity.isEmpty {
                client.state = .writingIdentity
                peripheral.writeValue(localIdentity, for: rxChar, type: .withoutResponse)
                // Move to established right after — there's no didWriteValueFor
                // callback for .withoutResponse. Re-stamp connectedAt so the
                // UI's "Connected Xs" starts from a meaningful point (the
                // moment the link is actually usable, not when CB first
                // returned didConnect).
                client.state = .established
                client.connectedAt = Date()
                // Kick a one-shot RSSI read immediately so the UI doesn't
                // wait the full poll interval for the first sample.
                peripheral.readRSSI()
            } else {
                emitError("warning", "no localIdentity or rxChar; handshake incomplete")
            }

        case txCharCBUUID:
            // Inbound fragment from peer. Pass raw bytes up; upstream
            // BLEInterface handles reassembly via BLEFragmentation.
            // Filter 1-byte 0x00 keepalive — upstream does this too but
            // we avoid the Python-side callback overhead for a no-op.
            if value.count == 1 && value[0] == 0x00 { return }
            callbackInvoker?.invoke(slot: .onDataReceived, args: [address, value])

        default:
            break
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            emitError("warning", "didWriteValueFor error uuid=\(characteristic.uuid): \(error)")
        }
    }

    /// Result of a `peripheral.readRSSI()` call. The `rssiPollTask` kicks
    /// these requests every ~3s for established peers; the value lands on
    /// the BleGattClient where getConnectionDetails picks it up.
    public func peripheral(
        _ peripheral: CBPeripheral,
        didReadRSSI RSSI: NSNumber,
        error: Error?
    ) {
        if let error {
            emitError("warning", "didReadRSSI error addr=\(peripheral.identifier.uuidString): \(error)")
            return
        }
        let address = peripheral.identifier.uuidString
        let value = RSSI.intValue
        // CB sometimes returns 127 / -127 / 0 as sentinels; ignore those
        // samples (matches the scan-path filter in didDiscover) so a sentinel
        // doesn't overwrite a good RSSI that getConnectionDetails() surfaces.
        guard value != 127, value != -127, value != 0 else { return }
        gattClients[address]?.rssi = value
    }
}

// MARK: - CBPeripheralManagerDelegate

extension SwiftBLEBridge: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            emitInfo("peripheralManager poweredOn")
            setUpGattServiceIfNeeded()
            tryStartAdvertiseLocked()
        case .poweredOff:
            emitError("warning", "peripheralManager poweredOff")
        case .unauthorized:
            emitError("critical", "peripheralManager unauthorized")
        case .unsupported:
            emitError("critical", "peripheralManager unsupported on this device")
        case .resetting:
            emitError("warning", "peripheralManager resetting")
        case .unknown:
            emitInfo("peripheralManager state unknown")
        @unknown default:
            emitInfo("peripheralManager state \(peripheral.state.rawValue)")
        }
    }

    public func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        if let error {
            emitError("warning", "advertise start failed: \(error)")
        } else {
            emitInfo("advertise-confirmed")
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        if let error {
            emitError("critical", "service add failed: \(error)")
            gattServiceAdded = false
        } else {
            emitInfo("service added uuid=\(service.uuid.uuidString)")
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        // Identity characteristic — return the local 16-byte identity hash.
        if request.characteristic.uuid == identityCharCBUUID {
            let value = localIdentity
            request.value = value
            peripheral.respond(to: request, withResult: .success)
            return
        }
        peripheral.respond(to: request, withResult: .requestNotSupported)
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        // CBPeripheralManager requires exactly one respond(to:withResult:) per
        // didReceiveWrite — passing the first request — and that single reply
        // ACKs the whole batch. Responding per-request throws "respond called
        // more than once" and drops the ATT transaction, so accumulate the
        // result and reply once after processing every request.
        var result: CBATTError.Code = .success
        for request in requests {
            guard request.characteristic.uuid == rxCharCBUUID,
                  let value = request.value else {
                result = .writeNotPermitted
                continue
            }
            let address = request.central.identifier.uuidString
            let peer = gattServerPeers[address] ?? BleGattServerPeer(central: request.central)
            gattServerPeers[address] = peer
            peer.mtu = request.central.maximumUpdateValueLength

            if peer.state == .awaitingIdentity {
                // First write per central is the 16-byte identity handshake.
                if value.count == BleConstants.identitySize {
                    peer.identity = value
                    let identityHex = hex(value)
                    callbackInvoker?.invoke(slot: .onIdentityReceived, args: [address, identityHex])

                    if let invoker = callbackInvoker {
                        let isDup = invoker.invokeBool(
                            slot: .onDuplicateIdentityDetected,
                            args: [address, value]
                        )
                        if isDup {
                            emitInfo("duplicate identity at peripheral peer \(address); dropping")
                            // CBPeripheralManager doesn't expose a "kick this
                            // subscriber" op — the best we can do is stop
                            // notifying them. Upstream interface ignores
                            // duplicates by identity hash anyway.
                            gattServerPeers.removeValue(forKey: address)
                            continue
                        }
                    }

                    if peer.mtu > 0 {
                        callbackInvoker?.invoke(slot: .onMtuNegotiated, args: [address, peer.mtu])
                    }
                    callbackInvoker?.invoke(slot: .onDeviceConnected, args: [address, value])
                    peer.state = .established
                    // Re-stamp connectedAt at the moment handshake completes
                    // (was init-time on subscribe, but subscribe happens
                    // before the identity write).
                    peer.connectedAt = Date()
                } else {
                    emitError("warning", "first write wasn't 16-byte handshake; len=\(value.count)")
                }
            } else {
                // Established — data fragment from peer. Drop 0x00 keepalive.
                if !(value.count == 1 && value[0] == 0x00) {
                    callbackInvoker?.invoke(slot: .onDataReceived, args: [address, value])
                }
            }
        }
        // Single response for the whole batch, per the CB contract.
        if let first = requests.first {
            peripheral.respond(to: first, withResult: result)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == txCharCBUUID else { return }
        let address = central.identifier.uuidString
        let peer = gattServerPeers[address] ?? BleGattServerPeer(central: central)
        peer.mtu = central.maximumUpdateValueLength
        gattServerPeers[address] = peer
        emitInfo("central subscribed addr=\(address) mtu=\(peer.mtu)")
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let address = central.identifier.uuidString
        guard let peer = gattServerPeers.removeValue(forKey: address) else { return }
        if peer.state == .established {
            callbackInvoker?.invoke(slot: .onDeviceDisconnected, args: [address])
        }
    }

    public func peripheralManagerIsReady(
        toUpdateSubscribers peripheral: CBPeripheralManager
    ) {
        // Drain queued notifies that hit backpressure earlier. updateValue's
        // transmit queue is global to the peripheral manager, so a `false`
        // means waiting for the next ready callback — but `break` (not
        // `return`) so one peer's backpressure or per-central failure doesn't
        // strand the remaining peers' queued frames.
        guard let tx = serverTxChar else { return }
        for (_, peer) in gattServerPeers {
            while let next = peer.pendingNotifies.first {
                let ok = peripheral.updateValue(next, for: tx, onSubscribedCentrals: [peer.central])
                if !ok { break }  // this peer backpressured/failed — move to the next
                peer.pendingNotifies.removeFirst()
            }
        }
    }
}

#else

// Non-iOS / non-Mac build (e.g., Linux SwiftPM CI) — degenerate stub so
// `swift build` succeeds without CoreBluetooth.
public final class SwiftBLEBridge: @unchecked Sendable {
    public static let shared = SwiftBLEBridge()
    public init() {}
    public var isStarted: Bool { false }
    public func setCallbackInvoker(_ invoker: BleCallbackInvoker?) {}
    public func setIdentity(_ identity: Data) {}
    public func configurePower(_ settings: BlePowerSettings) {}
    public func start(serviceUuid: String, rxCharUuid: String, txCharUuid: String, identityCharUuid: String) {}
    public func stop() {}
    public func startScanning() {}
    public func stopScanning() {}
    public func startAdvertising(deviceName: String?) {}
    public func stopAdvertising() {}
    public func connect(address: String) {}
    public func disconnect(address: String) {}
    public func send(address: String, data: Data) {}
    public func getConnectedPeers() -> [String] { [] }
    public func getPeerIdentity(address: String) -> String? { nil }
    public func getPeerAddress(identityHashHex: String) -> String? { nil }
    public func getPeerRssi(address: String) -> Int? { nil }
    public func getConnectionDetails() -> [BleConnectionDetails] { [] }
}

#endif
