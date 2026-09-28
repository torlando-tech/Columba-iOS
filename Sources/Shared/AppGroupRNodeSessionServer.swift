//
//  AppGroupRNodeSessionServer.swift
//  Shared
//
//  App side of the Model B Python RNode session seam. CoreBluetooth can't run in
//  the Network Extension, so the app owns the real CoreBluetooth NUS radio (the
//  shipping `PythonRNodeBLESessionRegistry`, ReticulumSwift-free). This server
//  relays the NE's `columba_rnode_session_*` commands to the radio and the
//  radio's state / data / failure back over the App-Group seam.
//
//  The Python RNode driver is POLL-BASED (it spins `read` / `state` in a loop),
//  so rather than push events, this server runs a fast poller that drains the
//  radio's rx buffer and reads its state / failure for each live session, and
//  forwards any change to the NE. The NE's local per-session cache then answers
//  the Python driver's `state` / `read` / `failure` polls. Writes are
//  event-driven (NE `.write` -> registry `writeSync` -> `.writeResult`), not
//  polled, so write latency is just the seam + CoreBluetooth write time.
//
//  Pure Foundation (no ReticulumSwift / no CoreBluetooth), so it stays in the
//  Shared module and is unit-testable with an in-memory loopback + a fake driver.
//  The real CoreBluetooth driver (`PythonRNodeSessionDriver`) lives in the
//  ColumbaApp target and is injected.
//

import Foundation

/// The radio the server drives. Implemented in the ColumbaApp target by
/// `PythonRNodeSessionDriver` (wraps `PythonRNodeBLESessionRegistry`). The handle
/// space is the radio's own (the registry's per-session handles), NOT the NE's -
/// the server maps (name, id) <-> radio handle and forwards events keyed by
/// (name, id) so the NE resolves its own local handle.
public protocol RNodeSessionRadioDriver: AnyObject, Sendable {
    /// Open a session. Returns the radio's handle (>0 ok, <=0 fail). The
    /// underlying connect is async; state transitions arrive via `state`.
    @discardableResult
    func openSession(deviceName: String, deviceIdentifier: String?) -> Int32
    /// Close the radio session.
    func closeSession(radioHandle: Int32)
    /// Current link state + failure reason (nil if the session is gone).
    func state(radioHandle: Int32) -> (RNodeSessionLinkState, String?)?
    /// Typed failure code (0 none, 1 failed, 2 pairing_required).
    func failure(radioHandle: Int32) -> Int32
    /// Drain the rx buffer (returns empty if nothing pending).
    func read(radioHandle: Int32) -> Data
    /// Synchronous write; returns the byte count written (== data.count on
    /// success, <0 on error).
    @discardableResult
    func write(radioHandle: Int32, data: Data) -> Int32
    /// RNS online/offline signal (drives CONNECTING vs CONNECTED).
    @discardableResult
    func setOnline(radioHandle: Int32, online: Bool) -> Bool
}

public final class AppGroupRNodeSessionServer: @unchecked Sendable {

    private let transport: RNodeSessionSeamWire
    private let driver: RNodeSessionRadioDriver
    private let log: (String) -> Void

    /// UI-facing link-state sink (the app wires this to its `applyRNodeLinkState`).
    /// Fires on every poll that observes a state change for a live session, so the
    /// Settings "connected" badge tracks the real CoreBluetooth link even though
    /// the Python driver (in the NE) is the authoritative RNS interface.
    private let onLinkStateChange: ((RNodeSessionLinkState, String?) -> Void)?

    private let lock = NSLock()
    private var started = false
    private var inboundTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    /// (name, id) key -> radio handle. One session per physical RNode.
    private struct Key: Hashable { let name: String; let id: String? }
    private var byKey: [Key: Int32] = [:]
    private var keyByHandle: [Int32: Key] = [:]

    /// Last state / failure forwarded per radio handle (change detection).
    private var lastState: [Int32: RNodeSessionLinkState] = [:]
    private var lastFailure: [Int32: Int32] = [:]
    /// Last failure reason per radio handle (carried to the UI sink on `.failed`).
    private var lastReason: [Int32: String?] = [:]

    /// Poll interval. The Python driver polls its own cache at 50 ms; this runs
    /// ~3x faster so a state / data change reaches the NE well within one driver
    /// poll. Coarse enough to stay cheap when idle (each tick is a handful of
    /// lock-guarded reads).
    private let pollIntervalNanos: UInt64

    public init(
        transport: RNodeSessionSeamWire,
        driver: RNodeSessionRadioDriver,
        log: @escaping (String) -> Void = { _ in },
        onLinkStateChange: ((RNodeSessionLinkState, String?) -> Void)? = nil,
        pollIntervalNanos: UInt64 = 15_000_000
    ) {
        self.transport = transport
        self.driver = driver
        self.log = log
        self.onLinkStateChange = onLinkStateChange
        self.pollIntervalNanos = pollIntervalNanos
    }

    // MARK: - Lifecycle

    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        transport.start()
        lock.unlock()
        inboundTask = Task { [weak self] in
            guard let self else { return }
            for await msg in self.transport.inbound { self.handle(msg) }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanos ?? 15_000_000)
                self?.pollSessions()
            }
        }
        log("[RNODE-APP] session server started; relaying NE commands to CoreBluetooth")
    }

    public func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        inboundTask?.cancel()
        pollTask?.cancel()
        inboundTask = nil
        pollTask = nil
        // Tear down every live radio session.
        let handles = Array(byKey.values)
        lock.unlock()
        for h in handles { driver.closeSession(radioHandle: h) }
        lock.lock()
        byKey.removeAll()
        keyByHandle.removeAll()
        lastState.removeAll()
        lastFailure.removeAll()
        lock.unlock()
        transport.stop()
        log("[RNODE-APP] session server stopped")
    }

    // MARK: - Inbound (NE -> app)

    private func handle(_ msg: RNodeSessionSeamMessage) {
        switch msg {
        case let .open(name, id):
            let key = Key(name: name, id: id)
            lock.lock()
            if byKey[key] != nil { lock.unlock(); return }  // already open
            lock.unlock()
            let handle = driver.openSession(deviceName: name, deviceIdentifier: id)
            lock.lock()
            if handle > 0 {
                byKey[key] = handle
                keyByHandle[handle] = key
                lastState[handle] = .disconnected
                lastFailure[handle] = 0
            }
            lock.unlock()
            log("[RNODE-APP] open '\(name)' -> radioHandle=\(handle)")

        case let .close(name, id):
            let key = Key(name: name, id: id)
            lock.lock()
            let handle = byKey.removeValue(forKey: key)
            if let h = handle {
                keyByHandle.removeValue(forKey: h)
                lastState.removeValue(forKey: h)
                lastFailure.removeValue(forKey: h)
            }
            lock.unlock()
            if let h = handle {
                driver.closeSession(radioHandle: h)
                log("[RNODE-APP] close '\(name)' (radioHandle=\(h))")
            }

        case let .write(name, id, reqId, data):
            let key = Key(name: name, id: id)
            lock.lock(); let handle = byKey[key]; lock.unlock()
            guard let h = handle else {
                transport.send(.writeResult(deviceName: name, deviceIdentifier: id, reqId: reqId, written: -1))
                return
            }
            let written = driver.write(radioHandle: h, data: data)
            transport.send(.writeResult(deviceName: name, deviceIdentifier: id, reqId: reqId, written: written))

        case let .setOnline(name, id, online):
            let key = Key(name: name, id: id)
            lock.lock(); let handle = byKey[key]; lock.unlock()
            if let h = handle { driver.setOnline(radioHandle: h, online: online) }

        case .stateChanged, .dataReceived, .writeResult, .failureChanged:
            break  // app->NE direction; the server never receives these
        }
    }

    // MARK: - Poller (app -> NE)

    private func pollSessions() {
        lock.lock()
        let snapshots = byKey.map { (key: $0.key, handle: $0.value) }
        lock.unlock()

        for snap in snapshots {
            guard let key = keyByHandleSafe(snap.handle) else { continue }
            // State change?
            if let (state, reason) = driver.state(radioHandle: snap.handle) {
                lock.lock()
                let changed = lastState[snap.handle] != state
                if changed {
                    lastState[snap.handle] = state
                    lastReason[snap.handle] = reason
                }
                lock.unlock()
                if changed {
                    transport.send(.stateChanged(deviceName: key.name, deviceIdentifier: key.id, state: state, reason: reason))
                    // Surface the real CoreBluetooth link to the UI badge. The Python
                    // driver (NE) is the authoritative RNS interface; this is the
                    // app-side proxy for the Settings "connected" indicator.
                    onLinkStateChange?(state, reason)
                }
            }
            // Failure code change?
            let failure = driver.failure(radioHandle: snap.handle)
            lock.lock()
            let failureChanged = lastFailure[snap.handle] != failure
            if failureChanged { lastFailure[snap.handle] = failure }
            lock.unlock()
            if failureChanged {
                transport.send(.failureChanged(deviceName: key.name, deviceIdentifier: key.id, code: failure))
            }
            // Inbound bytes?
            let data = driver.read(radioHandle: snap.handle)
            if !data.isEmpty {
                transport.send(.dataReceived(deviceName: key.name, deviceIdentifier: key.id, data: data))
            }
        }
    }

    private func keyByHandleSafe(_ handle: Int32) -> Key? {
        lock.lock(); defer { lock.unlock() }
        return keyByHandle[handle]
    }
}
