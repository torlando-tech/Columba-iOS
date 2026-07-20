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
    private var connectionTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var connectionAttemptTokens: [String: UUID] = [:]
    private let connectionTimeout: TimeInterval = 30.0

    // Discovered peripherals from scan, retained by `identifier.uuidString`.
    // `connect(address:)` looks them up here.
    private var discoveredPeripherals: [String: CBPeripheral] = [:]

    // Per-subscriber state for peripheral-mode (centrals connected TO us).
    // Keyed by `CBCentral.identifier.uuidString`.
    private var gattServerPeers: [String: BleGattServerPeer] = [:]


    // Cap on a peer's backpressure notify queue so a stuck or vanished
    // subscriber can't grow pendingNotifies without bound.
    private let maxPendingNotifies = 128

    // Same bound for the central-role per-client outbound write queue.
    private let maxPendingClientWrites = 128

    // Mutable characteristics published by our peripheral-mode GATT server.
    // Set once during start(); never re-added (iOS broadcasts Service Changed
    // on re-add which can break subscribed centrals).
    private var serverRxChar: CBMutableCharacteristic?
    private var serverTxChar: CBMutableCharacteristic?
    private var serverIdentityChar: CBMutableCharacteristic?
    private var gattServiceAdded: Bool = false
    private var gattServiceAdding: Bool = false

    // MARK: - Service UUIDs (set in start; injected by Python driver)

    private var serviceCBUUID: CBUUID = BleConstants.serviceCBUUID
    private var rxCharCBUUID: CBUUID = BleConstants.rxCharCBUUID
    private var txCharCBUUID: CBUUID = BleConstants.txCharCBUUID
    private var identityCharCBUUID: CBUUID = BleConstants.identityCharCBUUID

    // MARK: - State-restoration identifiers (Track C8 — background BLE wake)

    /// Stable restore identifiers handed to CoreBluetooth so iOS can RELAUNCH
    /// the app (into the background) on a BLE event for a peer we were
    /// connected/scanning/advertising to, then hand the SAME manager instances
    /// back via `willRestoreState`. These strings MUST be stable across launches
    /// — iOS keys its preserved manager state on them. Changing them orphans the
    /// preserved state. Process-wide constants since there is exactly one
    /// central + one peripheral manager per app (see `shared`).
    public static let centralRestoreIdentifier = "network.columba.ble.central"
    public static let peripheralRestoreIdentifier = "network.columba.ble.peripheral"

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

    /// Replay native links that survived a Python backend restart or a
    /// CoreBluetooth state-restoration wake. Android does this when Python
    /// registers `onConnected`; iOS uses an explicit call because all callback
    /// slots share one invoker rather than individual native setters.
    public func syncExistingConnections() {
        queue.async { [weak self] in
            guard let self, let invoker = self.callbackInvoker else { return }
            for (address, client) in self.gattClients where client.state == .established {
                guard let identity = client.peerIdentity else { continue }
                invoker.invoke(slot: .onIdentityReceived, args: [address, self.hex(identity)])
                invoker.invoke(slot: .onMtuNegotiated, args: [address, client.mtu])
                invoker.invoke(slot: .onDeviceConnected, args: [address, identity])
            }
            for (address, peer) in self.gattServerPeers where peer.state == .established {
                guard let identity = peer.identity else { continue }
                invoker.invoke(slot: .onIdentityReceived, args: [address, self.hex(identity)])
                invoker.invoke(slot: .onMtuNegotiated, args: [address, peer.mtu])
                invoker.invoke(slot: .onDeviceConnected, args: [address, identity])
            }
        }
    }

    /// Re-publish the native identity for a surviving link when Python has
    /// lost its address mapping. Returns false when no identified peer exists.
    public func requestIdentityResync(address: String) -> Bool {
        queue.sync {
            guard let invoker = callbackInvoker else { return false }
            if let identity = gattClients[address]?.peerIdentity {
                invoker.invoke(slot: .onIdentityReceived, args: [address, hex(identity)])
                return true
            }
            if let identity = gattServerPeers[address]?.identity {
                invoker.invoke(slot: .onIdentityReceived, args: [address, hex(identity)])
                return true
            }
            return false
        }
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
            //
            // Track C8 — state-restoration / background BLE wake: pass the
            // stable restore identifiers so iOS preserves these managers'
            // state across an app kill and RELAUNCHES us (into the background)
            // on a BLE event for a preserved peer, handing the same managers
            // back via `centralManager(_:willRestoreState:)` /
            // `peripheralManager(_:willRestoreState:)`. Opting in here is what
            // arms `UIApplication.LaunchOptionsKey.bluetoothCentrals` /
            // `.bluetoothPeripherals` at relaunch. For iOS to actually hand the
            // restored manager back, the app must RE-CREATE a manager with the
            // SAME restore identifier EARLY in launch — see
            // `SwiftBLEBridge.restoreAtLaunch()` and its call site in the app's
            // launch path (ColumbaApp).
            //
            // ────────────────────────────────────────────────────────────────
            // DELIVERY CAVEAT (read before relying on background wake):
            // The wake itself (relaunch + manager hand-back) is wired here in
            // native Swift. But the BLE message DELIVERY path — turning inbound
            // GATT bytes into a processed + notified LXMF message — is currently
            // Python-coupled: SwiftBLEBridge routes `on_data_received` (and the
            // rest of the BleCallbackSlot callbacks) through `callbackInvoker`
            // into the embedded Python RNS stack (IOSBLEDriver.py /
            // PythonBLECallbackBridge). On the SWIFT backend (Model B's target)
            // there is NO native BLE delivery path yet, so a background BLE wake
            // only results in a *delivered + notified* message when the PYTHON
            // backend is the active one and is (re)started early enough in the
            // relaunch to re-install the callbackInvoker. Native-Swift BLE
            // delivery is a deliberate follow-on; until it lands, treat C8's wake
            // as Python-backend-only for end-to-end delivery. Scope is BLE-direct;
            // RNode-over-iOS now runs Model B (radio hosted in the app via
            // reticulum-swift BLETransport with its own CBCentralManager, RNS in
            // the Network Extension), outside this mesh restore-identifier scope.
            // ────────────────────────────────────────────────────────────────
            if self.centralManager == nil {
                self.centralManager = CBCentralManager(
                    delegate: self,
                    queue: queue,
                    options: [
                        CBCentralManagerOptionRestoreIdentifierKey:
                            Self.centralRestoreIdentifier
                    ]
                )
            }
            if self.peripheralManager == nil {
                self.peripheralManager = CBPeripheralManager(
                    delegate: self,
                    queue: queue,
                    options: [
                        CBPeripheralManagerOptionRestoreIdentifierKey:
                            Self.peripheralRestoreIdentifier
                    ]
                )
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

    /// Track C8 — at-launch re-instantiation for background BLE wake.
    ///
    /// Call this EARLY in the app's launch path (before the run loop settles)
    /// when iOS has relaunched the app for a CoreBluetooth event — i.e. when
    /// `UIApplication.LaunchOptionsKey.bluetoothCentrals` and/or
    /// `.bluetoothPeripherals` are present in `launchOptions`, or simply
    /// unconditionally at every launch (cheap, and the only reliable trigger
    /// in a pure-SwiftUI app that has no `application(_:didFinishLaunching…)`
    /// to read `launchOptions` from — see the call-site note in the app).
    ///
    /// Re-creating a `CBCentralManager` / `CBPeripheralManager` with the SAME
    /// restore identifier is the documented contract that makes iOS replay the
    /// preserved state through `willRestoreState`. If we don't re-create the
    /// manager promptly at relaunch, iOS discards the preserved state and the
    /// wake is wasted.
    ///
    /// This intentionally does NOT call `start(...)` (which needs the per-
    /// session service/char UUIDs the Python driver injects, and flips
    /// `isStartedFlag` / starts scanning+advertising). It only re-materialises
    /// the managers so the restore handshake completes; the regular
    /// `start(...)` path (driven by the active backend bringing BLE up) then
    /// re-adopts the rest of the session. The manager UUIDs default to
    /// `BleConstants` until `start(...)` overrides them, which is correct — the
    /// service/char UUIDs are fixed wire constants (see BleConstants), so the
    /// restored peripherals re-wire against the right service even before
    /// `start(...)` runs.
    ///
    /// NOTE (delivery): re-creating the managers re-arms the wake and re-wires
    /// CoreBluetooth state, but inbound bytes are only turned into a notified
    /// message once the active backend's delivery path is live (Python-backend-
    /// only today — see the DELIVERY CAVEAT in `start(...)`). The app's launch
    /// path should kick the backend's BLE bring-up alongside calling this.
    public func restoreAtLaunch() {
        queue.sync {
            if self.centralManager == nil {
                self.centralManager = CBCentralManager(
                    delegate: self,
                    queue: queue,
                    options: [
                        CBCentralManagerOptionRestoreIdentifierKey:
                            Self.centralRestoreIdentifier
                    ]
                )
            }
            if self.peripheralManager == nil {
                self.peripheralManager = CBPeripheralManager(
                    delegate: self,
                    queue: queue,
                    options: [
                        CBPeripheralManagerOptionRestoreIdentifierKey:
                            Self.peripheralRestoreIdentifier
                    ]
                )
            }
        }
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
            for task in connectionTimeoutTasks.values { task.cancel() }
            connectionTimeoutTasks.removeAll()
            connectionAttemptTokens.removeAll()
            discoveredPeripherals.removeAll()
            gattServerPeers.removeAll()
            serverRxChar = nil
            serverTxChar = nil
            serverIdentityChar = nil
            gattServiceAdded = false
            gattServiceAdding = false
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
            //
            // Drop the callback invoker INSIDE this serialized block:
            // cancelPeripheralConnection above makes CoreBluetooth dispatch
            // didDisconnectPeripheral asynchronously onto `queue`, which
            // always runs after this block completes. Clearing here (rather
            // than via a second setCallbackInvoker(nil) hop that races those
            // async disconnects) guarantees no post-stop .onDeviceDisconnected
            // reaches Python for peers it has already torn down. Re-installed
            // by startBLEInterface on the next start.
            callbackInvoker = nil
        }
    }

    /// Build + register the GATT service exactly once. Called from
    /// `peripheralManagerDidUpdateState(.poweredOn)`. Re-adding the service
    /// at runtime causes iOS to broadcast Service Changed which can break
    /// subscribed centrals, so we guard against re-add with `gattServiceAdded`.
    fileprivate func setUpGattServiceIfNeeded() {
        guard let pm = peripheralManager,
              pm.state == .poweredOn,
              !gattServiceAdded,
              !gattServiceAdding else { return }

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
        gattServiceAdding = true
        pm.add(service)

        serverRxChar = rx
        serverTxChar = tx
        serverIdentityChar = identity
        emitInfo("gatt-service-add-requested serviceUuid=\(serviceCBUUID.uuidString)")
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

    private func armConnectionTimeoutLocked(address: String, client: BleGattClient) {
        cancelConnectionTimeoutLocked(address: address)
        let attemptToken = UUID()
        connectionAttemptTokens[address] = attemptToken
        connectionTimeoutTasks[address] = Task { [weak self, weak client] in
            try? await Task.sleep(nanoseconds: UInt64((self?.connectionTimeout ?? 30.0) * 1_000_000_000))
            guard !Task.isCancelled, let self, let armedClient = client else { return }
            self.queue.async {
                guard self.connectionAttemptTokens[address] == attemptToken,
                      let currentClient = self.gattClients[address],
                      currentClient === armedClient,
                      currentClient.state != .established else {
                    if self.connectionAttemptTokens[address] == attemptToken {
                        self.connectionTimeoutTasks.removeValue(forKey: address)
                        self.connectionAttemptTokens.removeValue(forKey: address)
                    }
                    return
                }
                currentClient.state = .failed
                self.connectionTimeoutTasks.removeValue(forKey: address)
                self.connectionAttemptTokens.removeValue(forKey: address)
                self.emitError("warning", "Connection timeout to \(address)")
                self.centralManager?.cancelPeripheralConnection(armedClient.peripheral)
            }
        }
    }

    private func cancelConnectionTimeoutLocked(address: String) {
        connectionTimeoutTasks.removeValue(forKey: address)?.cancel()
        connectionAttemptTokens.removeValue(forKey: address)
    }

    public func connect(address: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let cm = self.centralManager else { return }
            guard self.gattClients[address] == nil else {
                self.emitInfo("connect ignored; native client already retained addr=\(address)")
                return
            }
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
            let client = BleGattClient(peripheral: peripheral)
            client.state = .connecting
            self.gattClients[address] = client
            cm.connect(peripheral, options: nil)
            self.armConnectionTimeoutLocked(address: address, client: client)
            self.emitInfo("connect-issued addr=\(address)")
        }
    }

    public func disconnect(address: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let cm = self.centralManager,
                  let client = self.gattClients[address] else { return }
            client.state = .failed
            self.cancelConnectionTimeoutLocked(address: address)
            cm.cancelPeripheralConnection(client.peripheral)
        }
    }

    public func send(address: String, data: Data) -> Bool {
        queue.sync {
            // Central role: queue + drain under transmit-queue backpressure.
            // writeValue(.withoutResponse) silently drops once CoreBluetooth's
            // per-peripheral queue is full (iOS 11+), so gate on
            // canSendWriteWithoutResponse and resume in peripheralIsReady.
            if let client = gattClients[address], client.rxChar != nil {
                guard client.pendingWrites.count < maxPendingClientWrites else {
                    emitError("warning", "client pendingWrites full (\(maxPendingClientWrites)) for \(address); rejecting frame")
                    return false
                }
                client.pendingWrites.append(data)
                // RX discovery precedes the mandatory identity
                // write-with-response. Accept application frames into the
                // bounded queue, but never let them overtake that handshake.
                if client.state == .established {
                    drainClientWritesLocked(client)
                }
                return true
            }
            // Peripheral role: notify on TX char to the specific subscriber.
            if let peer = gattServerPeers[address],
               serverTxChar != nil,
               peripheralManager != nil {
                // Always enqueue then drain in FIFO order. Sending a new frame
                // directly while pendingNotifies is non-empty would jump it
                // ahead of frames already queued behind backpressure — the peer
                // would receive fragments out of order. Bounded so a stuck or
                // vanished subscriber can't grow the queue without limit.
                guard peer.pendingNotifies.count < maxPendingNotifies else {
                    emitError("warning", "pendingNotifies full (\(maxPendingNotifies)) for \(address); rejecting frame")
                    return false
                }
                peer.pendingNotifies.append(data)
                // Subscription can arrive before the remote central's first
                // 16-byte identity write. Preserve ordering by holding
                // application notifications until that write is accepted.
                if peer.state == .established {
                    drainPeerNotifiesLocked(peer)
                }
                return true
            }
            emitError("warning", "send: no client / no server peer for \(address)")
            return false
        }
    }

    /// Drain a central-role client's queued writes while its peripheral has
    /// transmit-queue space. Called on `queue` (from send() and the central
    /// peripheralIsReady delegate).
    private func drainClientWritesLocked(_ client: BleGattClient) {
        guard let rx = client.rxChar else { return }
        let p = client.peripheral
        while !client.pendingWrites.isEmpty, p.canSendWriteWithoutResponse {
            p.writeValue(client.pendingWrites.removeFirst(), for: rx, type: .withoutResponse)
        }
    }

    /// Drain a peripheral-role peer's queued notifies in FIFO order while the
    /// (manager-global) transmit queue accepts them. Called on `queue` from
    /// send() and peripheralManagerIsReady.
    private func drainPeerNotifiesLocked(_ peer: BleGattServerPeer) {
        guard let pm = peripheralManager, let tx = serverTxChar else { return }
        while let next = peer.pendingNotifies.first {
            guard pm.updateValue(next, for: tx, onSubscribedCentrals: [peer.central]) else { break }
            peer.pendingNotifies.removeFirst()
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

    /// Resolve simultaneous central+peripheral links by usable characteristic
    /// capacity first. Equal-capacity links use the identity ordering shared
    /// with Android: the lower identity keeps central role. Returning an old
    /// address means the candidate is the deterministic survivor and Python
    /// must migrate its address mapping before publication.
    private func resolveDuplicateLocked(
        candidateAddress: String,
        candidateIdentity: Data,
        candidateRole: BleConnectionRole
    ) -> String? {
        guard localIdentity.count == BleConstants.identitySize,
              candidateIdentity != localIdentity else { return nil }

        let wantedRole: BleConnectionRole =
            localIdentity.lexicographicallyPrecedes(candidateIdentity) ? .central : .peripheral

        switch candidateRole {
        case .central:
            guard let candidate = gattClients[candidateAddress],
                  let old = gattServerPeers.first(where: {
                      $0.key != candidateAddress && $0.value.identity == candidateIdentity
                  }) else { return nil }
            let candidateMTU = candidate.mtu
            let existingMTU = old.value.mtu
            let candidateWins = candidateMTU > existingMTU ||
                (candidateMTU == existingMTU && candidateRole == wantedRole)
            guard candidateWins else { return nil }
            gattServerPeers.removeValue(forKey: old.key)
            emitInfo(
                "dual-link convergence keep=central old=\(old.key) new=\(candidateAddress) " +
                "centralMtu=\(candidateMTU) peripheralMtu=\(existingMTU)"
            )
            return old.key

        case .peripheral:
            guard let candidate = gattServerPeers[candidateAddress],
                  let old = gattClients.first(where: {
                      $0.key != candidateAddress && $0.value.peerIdentity == candidateIdentity
                  }) else { return nil }
            let candidateMTU = candidate.mtu
            let existingMTU = old.value.mtu
            let candidateWins = candidateMTU > existingMTU ||
                (candidateMTU == existingMTU && candidateRole == wantedRole)
            guard candidateWins else { return nil }
            old.value.state = .failed
            cancelConnectionTimeoutLocked(address: old.key)
            centralManager?.cancelPeripheralConnection(old.value.peripheral)
            emitInfo(
                "dual-link convergence keep=peripheral old=\(old.key) new=\(candidateAddress) " +
                "peripheralMtu=\(candidateMTU) centralMtu=\(existingMTU)"
            )
            return old.key
        }
    }

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
    public func getPeerRole(address: String) -> BleConnectionRole? {
        queue.sync {
            if gattClients[address]?.state == .established { return .central }
            if gattServerPeers[address]?.state == .established { return .peripheral }
            return nil
        }
    }
    public func getPeerMtu(address: String) -> Int? {
        queue.sync {
            if let client = gattClients[address], client.state == .established { return client.mtu }
            if let peer = gattServerPeers[address], peer.state == .established { return peer.mtu }
            return nil
        }
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
              gattServiceAdded,
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

    /// Track C8 — central-side state restoration. CoreBluetooth invokes this
    /// (on `queue`, BEFORE `centralManagerDidUpdateState`) when the system has
    /// relaunched the app and is handing back a `CBCentralManager` we created
    /// with `centralRestoreIdentifier`. Re-adopt the preserved central state so
    /// the bridge's in-memory model matches what CoreBluetooth still holds:
    ///
    ///   • `CBCentralManagerRestoredStatePeripheralsKey` — peripherals that
    ///     were connected (or pending connection) when we were suspended. iOS
    ///     hands back the live `CBPeripheral` objects; we MUST take a strong ref
    ///     (re-populate `gattClients` / `discoveredPeripherals`) or it
    ///     deallocates them and drops the connection. We re-set ourselves as
    ///     delegate and, for already-`.connected` peripherals, re-drive service
    ///     discovery so the GATT handshake (identity read → connected) re-runs
    ///     exactly as in the normal `didConnect` path.
    ///   • `CBCentralManagerRestoredStateScanServicesKey` /
    ///     `…ScanOptionsKey` — if we were scanning when killed, mark scan as
    ///     pending so `tryStartScanLocked()` (called from
    ///     `centralManagerDidUpdateState(.poweredOn)`, which fires right after
    ///     this) resumes it.
    ///
    /// Already on `queue` (CB delegate dispatch), so peer-state mutation here
    /// follows the same locking discipline as the other delegate callbacks.
    ///
    /// DELIVERY CAVEAT: re-adopting here re-wires CoreBluetooth, but the
    /// resulting `on_data_received` only becomes a notified message via the
    /// Python delivery path (Python-backend-only today — see the block in
    /// `start(...)`). Native-Swift BLE delivery is a follow-on.
    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        let restoredPeripherals =
            (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        emitInfo("centralManager willRestoreState peripherals=\(restoredPeripherals.count)")

        for peripheral in restoredPeripherals {
            let address = peripheral.identifier.uuidString
            // Strong ref so iOS doesn't deallocate the restored peripheral.
            peripheral.delegate = self
            discoveredPeripherals[address] = peripheral
            let client = gattClients[address] ?? BleGattClient(peripheral: peripheral)
            gattClients[address] = client

            // Re-drive the handshake for peripherals CB still has connected.
            // Mirrors the normal didConnect adoption: stamp MTU, then discover
            // our service so didDiscoverServices → … → identity read re-runs.
            // Peripherals restored mid-connect (.connecting) are left for
            // CoreBluetooth to finish; its didConnect will adopt them normally.
            if peripheral.state == .connected {
                let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
                client.mtu = mtu
                client.state = .discoveringServices
                peripheral.discoverServices([serviceCBUUID])
                emitInfo("restored connected peripheral addr=\(address) mtu=\(mtu)")
            } else {
                client.state = .connecting
                emitInfo("restored pending peripheral addr=\(address) state=\(peripheral.state.rawValue)")
            }
        }

        // If a scan was in flight when we were killed, re-arm it. The actual
        // scanForPeripherals call happens in centralManagerDidUpdateState once
        // the manager reports .poweredOn (which lands right after this).
        if let scanServices = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID],
           !scanServices.isEmpty {
            pendingScanRequested = true
            emitInfo("restored scan request services=\(scanServices.map { $0.uuidString })")
        }
    }

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
        var serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString.lowercased() } ?? []
        // The native scan is already filtered by serviceCBUUID. CoreBluetooth
        // may omit the advertisement UUID list during restoration/background
        // discovery; preserve the proven match for BLEInterface's own filter.
        let configuredService = serviceCBUUID.uuidString.lowercased()
        if !serviceUUIDs.contains(configuredService) {
            serviceUUIDs.append(configuredService)
        }

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
        guard let currentClient = gattClients[address],
              currentClient.peripheral === peripheral else {
            emitError("warning", "didConnect for stale or unknown client \(address)")
            return
        }
        let client = currentClient
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
        guard let currentClient = gattClients[address],
              currentClient.peripheral === peripheral else {
            emitInfo("ignored stale didFailToConnect addr=\(address)")
            return
        }
        emitError("warning", "didFailToConnect addr=\(address) error=\(String(describing: error))")
        cancelConnectionTimeoutLocked(address: address)
        gattClients.removeValue(forKey: address)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let address = peripheral.identifier.uuidString
        guard let currentClient = gattClients[address],
              currentClient.peripheral === peripheral else {
            emitInfo("ignored stale didDisconnect addr=\(address)")
            return
        }
        cancelConnectionTimeoutLocked(address: address)
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
        // Android serialises this handshake: identity read → MTU → confirmed
        // notification subscription → identity write-with-response → connected.
        // Do not overlap the read and CCCD operation: CoreBluetooth usually
        // serialises them, but relying on that creates a race where Python can
        // see a connected peer before RX is usable.
        peripheral.readValue(for: identityChar)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let address = peripheral.identifier.uuidString
        if let error {
            emitError("warning", "notification subscription failed addr=\(address): \(error)")
            gattClients[address]?.state = .failed
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        guard characteristic.uuid == txCharCBUUID,
              characteristic.isNotifying,
              let client = gattClients[address],
              client.state == .subscribing,
              let rxChar = client.rxChar,
              localIdentity.count == BleConstants.identitySize else { return }

        client.notificationsReady = true
        client.state = .writingIdentity
        emitInfo("notifications-ready addr=\(address); writing identity")
        // Protocol v2.2 requires an ATT Write Request. Android waits for this
        // acknowledgement before publishing the connection to Python.
        peripheral.writeValue(localIdentity, for: rxChar, type: .withResponse)
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
            let identityHex = value.map { String(format: "%02x", $0) }.joined()

            // Synchronous duplicate-identity check must happen before publishing
            // the identity; the Python handler updates identity/address maps.
            if let invoker = callbackInvoker {
                let isDup = invoker.invokeBool(
                    slot: .onDuplicateIdentityDetected,
                    args: [address, identityHex]
                )
                if isDup {
                    if let oldAddress = resolveDuplicateLocked(
                        candidateAddress: address,
                        candidateIdentity: value,
                        candidateRole: .central
                    ) {
                        callbackInvoker?.invoke(
                            slot: .onAddressChanged,
                            args: [oldAddress, address, identityHex]
                        )
                        // Address migration may carry the old child
                        // interface's capacity. Re-publish the winning
                        // central link's role-specific CoreBluetooth value.
                        callbackInvoker?.invoke(
                            slot: .onMtuNegotiated,
                            args: [address, client.mtu]
                        )
                    } else {
                        emitInfo("duplicate identity at \(address); dropping non-deterministic central link")
                        centralManager?.cancelPeripheralConnection(peripheral)
                        return
                    }
                }
            }

            client.peerIdentity = value
            callbackInvoker?.invoke(slot: .onIdentityReceived, args: [address, identityHex])
            guard localIdentity.count == BleConstants.identitySize else {
                client.state = .failed
                emitError("warning", "local identity unavailable; handshake incomplete addr=\(address)")
                centralManager?.cancelPeripheralConnection(peripheral)
                return
            }
            client.state = .subscribing
            peripheral.setNotifyValue(true, for: client.txChar!)

        case txCharCBUUID:
            // Inbound fragment from peer. Pass raw bytes up; upstream
            // BLEInterface handles reassembly via BLEFragmentation.
            // BLEFragmentation frames always include the five-byte header.
            // Do not feed ATT-level keepalive/control values into Python
            // reassembly as malformed Reticulum fragments.
            if value.count < BleConstants.fragmentHeaderSize { return }
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
        let address = peripheral.identifier.uuidString
        if let error {
            emitError("warning", "didWriteValueFor error addr=\(address) uuid=\(characteristic.uuid): \(error)")
            if characteristic.uuid == rxCharCBUUID,
               gattClients[address]?.state == .writingIdentity {
                gattClients[address]?.state = .failed
                centralManager?.cancelPeripheralConnection(peripheral)
            }
            return
        }
        guard characteristic.uuid == rxCharCBUUID,
              let client = gattClients[address],
              client.state == .writingIdentity,
              client.notificationsReady,
              let peerIdentity = client.peerIdentity else { return }

        client.state = .established
        cancelConnectionTimeoutLocked(address: address)
        client.connectedAt = Date()
        if !client.connectedFired {
            client.connectedFired = true
            callbackInvoker?.invoke(slot: .onDeviceConnected, args: [address, peerIdentity])
        }
        drainClientWritesLocked(client)
        emitInfo("peer-established role=central addr=\(address) mtu=\(client.mtu)")
        peripheral.readRSSI()
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Central-role transmit queue freed up — drain the matching client's
        // queued writes. Delivered on the bridge's `queue`.
        guard let client = gattClients.values.first(where: { $0.peripheral === peripheral }) else { return }
        drainClientWritesLocked(client)
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

    /// Track C8 — peripheral-side state restoration. CoreBluetooth invokes this
    /// (on `queue`, BEFORE `peripheralManagerDidUpdateState`) when the system
    /// has relaunched the app and is handing back a `CBPeripheralManager` we
    /// created with `peripheralRestoreIdentifier`. Re-adopt the preserved
    /// peripheral (GATT-server) state:
    ///
    ///   • `CBPeripheralManagerRestoredStateServicesKey` — the published
    ///     `CBMutableService`(s) iOS preserved. We re-bind our
    ///     `serverRxChar` / `serverTxChar` / `serverIdentityChar` to the
    ///     restored characteristic objects and set `gattServiceAdded = true` so
    ///     the `setUpGattServiceIfNeeded()` call in
    ///     `peripheralManagerDidUpdateState(.poweredOn)` (which fires right
    ///     after this) does NOT re-`add(service:)`. Re-adding a service iOS
    ///     already holds makes it broadcast Service Changed, which breaks
    ///     subscribed centrals — the exact hazard `gattServiceAdded` guards
    ///     against in the normal path.
    ///   • `CBPeripheralManagerRestoredStateAdvertisementDataKey` — if we were
    ///     advertising when killed, mark advertise as pending so
    ///     `tryStartAdvertiseLocked()` resumes it once the manager reports
    ///     `.poweredOn`.
    ///
    /// Subscribed centrals are NOT in this dictionary — CoreBluetooth re-issues
    /// `didSubscribeTo` for restored subscriptions, which the existing delegate
    /// already adopts into `gattServerPeers`. Already on `queue` (CB delegate
    /// dispatch), so the same locking discipline as the other callbacks holds.
    ///
    /// DELIVERY CAVEAT: same as the central side — re-adoption re-wires the
    /// GATT server, but inbound writes only become notified messages via the
    /// Python delivery path today (see `start(...)`). Native-Swift delivery is
    /// a follow-on.
    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        let restoredServices =
            (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        emitInfo("peripheralManager willRestoreState services=\(restoredServices.count)")

        // Re-bind our characteristic refs from the restored service so
        // send()/drainPeerNotifiesLocked keep working against the same objects
        // CoreBluetooth still has published. Match by UUID — the wire constants
        // are fixed (see BleConstants).
        if let service = restoredServices.first(where: { $0.uuid == serviceCBUUID }) {
            for case let ch as CBMutableCharacteristic in (service.characteristics ?? []) {
                switch ch.uuid {
                case rxCharCBUUID:       serverRxChar = ch
                case txCharCBUUID:       serverTxChar = ch
                case identityCharCBUUID: serverIdentityChar = ch
                default: break
                }
            }
            // The service is already published — do NOT re-add it (would
            // trigger Service Changed). Flag as added so setUpGattServiceIfNeeded
            // becomes a no-op when poweredOn lands right after this.
            gattServiceAdded = true
            gattServiceAdding = false
            emitInfo("restored published service uuid=\(service.uuid.uuidString)")
        }

        // Resume advertising if we were advertising when suspended.
        if let adData = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any] {
            pendingAdvertiseRequested = true
            if let name = adData[CBAdvertisementDataLocalNameKey] as? String, !name.isEmpty {
                pendingAdvertiseDeviceName = name
            }
            emitInfo("restored advertise request name=\(pendingAdvertiseDeviceName ?? "<nil>")")
        }
    }

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            emitInfo("peripheralManager poweredOn")
            setUpGattServiceIfNeeded()
            if gattServiceAdded { tryStartAdvertiseLocked() }
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
        gattServiceAdding = false
        if let error {
            emitError("critical", "service add failed: \(error)")
            gattServiceAdded = false
            if peripheral.isAdvertising { peripheral.stopAdvertising() }
        } else {
            gattServiceAdded = true
            emitInfo("service added uuid=\(service.uuid.uuidString)")
            tryStartAdvertiseLocked()
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
                    let identityHex = hex(value)

                    if let invoker = callbackInvoker {
                        let isDup = invoker.invokeBool(
                            slot: .onDuplicateIdentityDetected,
                            args: [address, identityHex]
                        )
                        if isDup {
                            if let oldAddress = resolveDuplicateLocked(
                                candidateAddress: address,
                                candidateIdentity: value,
                                candidateRole: .peripheral
                            ) {
                                callbackInvoker?.invoke(
                                    slot: .onAddressChanged,
                                    args: [oldAddress, address, identityHex]
                                )
                            } else {
                                emitInfo("duplicate identity at peripheral peer \(address); dropping non-deterministic peripheral link")
                                // CBPeripheralManager cannot kick a subscribed
                                // central. Remove native state so it cannot be
                                // selected for sends; the remote deterministic
                                // resolver closes its matching central link.
                                gattServerPeers.removeValue(forKey: address)
                                continue
                            }
                        }
                    }

                    peer.identity = value
                    callbackInvoker?.invoke(slot: .onIdentityReceived, args: [address, identityHex])

                    if peer.mtu > 0 {
                        callbackInvoker?.invoke(slot: .onMtuNegotiated, args: [address, peer.mtu])
                    }
                    callbackInvoker?.invoke(slot: .onDeviceConnected, args: [address, value])
                    peer.state = .established
                    drainPeerNotifiesLocked(peer)
                    // Re-stamp connectedAt at the moment handshake completes
                    // (was init-time on subscribe, but subscribe happens
                    // before the identity write).
                    peer.connectedAt = Date()
                } else {
                    emitError("warning", "first write wasn't 16-byte handshake; len=\(value.count)")
                }
            } else {
                // Established — only complete BLEFragmentation frames belong
                // on the Reticulum data path.
                if value.count >= BleConstants.fragmentHeaderSize {
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
        // Transmit queue freed up — drain each peer's queued notifies in FIFO
        // order via the shared helper. Per-peer (not a global `return`) so one
        // peer's backpressure doesn't strand the others' queued frames.
        for (_, peer) in gattServerPeers {
            drainPeerNotifiesLocked(peer)
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
    public func syncExistingConnections() {}
    public func requestIdentityResync(address: String) -> Bool { false }
    public func start(serviceUuid: String, rxCharUuid: String, txCharUuid: String, identityCharUuid: String) {}
    public func stop() {}
    public func startScanning() {}
    public func stopScanning() {}
    public func startAdvertising(deviceName: String?) {}
    public func stopAdvertising() {}
    public func connect(address: String) {}
    public func disconnect(address: String) {}
    public func send(address: String, data: Data) -> Bool { false }
    public func getConnectedPeers() -> [String] { [] }
    public func getPeerIdentity(address: String) -> String? { nil }
    public func getPeerAddress(identityHashHex: String) -> String? { nil }
    public func getPeerRssi(address: String) -> Int? { nil }
    public func getPeerRole(address: String) -> BleConnectionRole? { nil }
    public func getPeerMtu(address: String) -> Int? { nil }
    public func getConnectionDetails() -> [BleConnectionDetails] { [] }
}

#endif
