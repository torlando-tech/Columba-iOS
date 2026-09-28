//
//  NERNodeCABIBridge.swift
//  ColumbaNetworkExtension
//
//  NE-side implementation of the `columba_rnode_session_*` C-ABI that
//  `IOSRNodeDriver.py` resolves via `ctypes.CDLL(None)`. In the NE process the
//  real CoreBluetooth NUS radio cannot run (CoreBluetooth is unavailable in a
//  Network Extension), so these symbols do NOT drive a radio directly - they
//  forward the command over the App-Group RNode-session seam to the app, where
//  `PythonRNodeBLESessionRegistry` (the same CoreBluetooth owner the shipping
//  Python path uses) performs the radio work.
//
//  This is the Model B analog of the app's `PythonRNodeBLEBridge.swift`:
//  identical symbol names + signatures (so the unmodified Python driver works in
//  both processes), different back end (seam forwarder vs in-process radio).
//
//      NE:  IOSRNodeDriver (Python) ──CDLL(None)──▶ NERNodeCABIBridge (this file)
//                                                   │  AppGroupRNodeSessionTransport
//      app: AppGroupRNodeSessionServer ──▶ PythonRNodeBLESessionRegistry (CoreBluetooth NUS)
//
//  The Python driver is POLL-BASED: it allocates a handle from `open`, polls
//  `state` until CONNECTED, then spins a tight `read` / `writeSync` loop, and
//  `close`s on teardown. So this forwarder keeps a LOCAL cache PER SESSION that
//  the app feeds via the inbound event stream:
//
//    • link state   - answered by `state(handle)` from the last `stateChanged`
//    • failure code - answered by `failure(handle)` from the last `failureChanged`
//    • rx buffer    - drained by `read(handle)` (the app pushes `dataReceived`)
//
//  `write(handle)` carries a `reqId` and blocks (bounded) on the matching
//  `writeResult` so it can report the real byte count the Python driver checks
//  (`written == len(data)`). `open` / `close` / `setOnline` are fire-and-forget.
//
//  Sessions are keyed by (deviceName, deviceIdentifier) - the CoreBluetooth
//  stable UUID when known, else the normalized name - so the NE's local handle
//  and the app's registry handle can differ while referring to the same
//  physical RNode.
//
//  C-ABI contract (mirrors `PythonRNodeBLEBridge.swift`):
//    open(name, id)           -> Int32  handle (>0 ok, <=0 fail)
//    close(handle)            -> Int32  0 ok, -1 fail
//    state(handle)            -> Int32  0 disconnected, 1 connecting, 2 connected, 3 failed
//    failure(handle)          -> Int32  0 none, 1 failed, 2 pairing_required
//    read(handle, out, cap)   -> Int32  bytes read (0 empty, -1 bad handle)
//    write(handle, in, count) -> Int32  bytes written (==count ok, <0 error)
//    setOnline(handle, on)    -> Int32  0 ok, -1 fail
//
import Foundation

/// A bounded, thread-safe completion for a forwarded `write`. `write()` blocks on
/// `wait`; the inbound `writeResult` handler calls `set` (from the NE's inbound
/// task, a different thread). Mirrors the app's in-process `writeSync` semaphore
/// pattern, but the signal arrives over the seam instead of an in-process closure.
private final class WriteCompletion: @unchecked Sendable {
    let ownerHandle: Int32
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var written: Int32 = -1

    init(ownerHandle: Int32) { self.ownerHandle = ownerHandle }
    func set(_ w: Int32) {
        lock.lock(); written = w; lock.unlock()
        semaphore.signal()
    }
    /// Block up to `timeout`; return the app's byte count, or -2 on timeout.
    func wait(timeout: TimeInterval) -> Int32 {
        let ok = semaphore.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return ok == .success ? written : -2
    }
}

final class NERNodeCABIBridge: @unchecked Sendable {
    static let shared = NERNodeCABIBridge()

    private let transport: AppGroupRNodeSessionTransport
    private let lock = NSLock()
    private var started = false
    private var inboundTask: Task<Void, Never>?
    private var nextHandle: Int32 = 1
    private var nextReqId: UInt32 = 0

    /// Per-session local cache. `state`/`failureCode`/`rxBuffer` are fed by the
    /// app→NE event stream; `open`/`write`/`close`/`setOnline` are forwarded.
    private struct Session {
        let deviceName: String
        let deviceIdentifier: String?
        var state: RNodeSessionLinkState = .disconnected
        var failureCode: Int32 = 0
        var online: Bool = false
        var rxBuffer: Data = Data()
    }

    /// Hard cap on the local rx buffer. KISS frames are small; an unbounded
    /// buffer means a stalled `read` (Python wedged) grows without limit. 1 MiB
    /// matches the app-side `maxBufferedBytes`.
    private let maxBufferedBytes = 1_048_576

    /// Bound a `write` block. The app's `writeSync` completes as soon as the
    /// CoreBluetooth write is queued (well under a second); a 10 s cap means a
    /// lost `writeResult` (app jettisoned mid-write) fails the write instead of
    /// hanging the Python driver's TX thread.
    private let writeTimeout: TimeInterval = 10

    private var sessions: [Int32: Session] = [:]
    private var pendingWrites: [UInt32: WriteCompletion] = [:]

    private init() {
        transport = AppGroupRNodeSessionTransport(role: .networkExtension)
    }

    // MARK: - Lifecycle

    /// Begin consuming app→NE events. Idempotent. Called on the first RNode
    /// command (the Python driver's `columba_rnode_session_open`).
    func ensureStarted() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        transport.start()
        inboundTask = Task { [weak self] in
            guard let self else { return }
            for await msg in self.transport.inbound { self.handle(msg) }
        }
        ExtensionDiagLog.log("[RNODE-NE] session forwarder started; relaying app radio events to Python")
    }

    // MARK: - C-ABI backing (called by the @_cdecl shims below)

    /// Allocate a local handle, forward `.open` to the app, return the handle.
    /// The app allocates its own registry handle for the (name, id) session;
    /// they are joined by the shared key, not the value.
    func open(deviceName: String, deviceIdentifier: String?) -> Int32 {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return -1 }
        ensureStarted()
        let key = Self.physicalKey(deviceIdentifier: deviceIdentifier, deviceName: name)
        lock.lock()
        // Reject a duplicate claim for the same physical RNode (mirrors the
        // app's registry): two live interfaces for one device would split the
        // single NUS byte stream.
        for s in sessions.values where Self.physicalKey(deviceIdentifier: s.deviceIdentifier, deviceName: s.deviceName) == key {
            lock.unlock()
            ExtensionDiagLog.log("[RNODE-NE] open rejected: duplicate physical RNode '\(name)'")
            return -2
        }
        let handle = allocateHandleLocked()
        sessions[handle] = Session(deviceName: name, deviceIdentifier: deviceIdentifier)
        lock.unlock()
        transport.send(.open(deviceName: name, deviceIdentifier: deviceIdentifier))
        ExtensionDiagLog.log("[RNODE-NE] open handle=\(handle) '\(name)'")
        return handle
    }

    func close(handle: Int32) -> Int32 {
        lock.lock()
        guard let session = sessions.removeValue(forKey: handle) else { lock.unlock(); return -1 }
        // Unblock any in-flight write for this session (the app is releasing the
        // radio; the blocked write() must not sit out its full timeout).
        for (reqId, completion) in pendingWrites where completion.ownerHandle == handle {
            completion.set(-1)
            pendingWrites[reqId] = nil
        }
        lock.unlock()
        transport.send(.close(deviceName: session.deviceName, deviceIdentifier: session.deviceIdentifier))
        ExtensionDiagLog.log("[RNODE-NE] close handle=\(handle) '\(session.deviceName)'")
        return 0
    }

    func state(handle: Int32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let s = sessions[handle] else { return Int32(RNodeSessionLinkState.disconnected.rawValue) }
        // Mirror the app's `publishedStateLocked`: a CONNECTED GATT link that
        // RNS has not yet marked online reports CONNECTING, so the Python
        // driver's poll waits until the interface is actually usable.
        if s.state == .connected && !s.online { return Int32(RNodeSessionLinkState.connecting.rawValue) }
        return Int32(s.state.rawValue)
    }

    func failure(handle: Int32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return sessions[handle]?.failureCode ?? 0
    }

    func read(handle: Int32, capacity: Int32) -> Data? {
        guard capacity > 0 else { return Data() }
        lock.lock()
        defer { lock.unlock() }
        guard var s = sessions[handle] else { return nil }
        let count = min(Int(capacity), s.rxBuffer.count)
        guard count > 0 else { return Data() }
        let out = s.rxBuffer.prefix(count)
        s.rxBuffer.removeFirst(count)
        sessions[handle] = s
        return Data(out)
    }

    func write(handle: Int32, data: Data) -> Int32 {
        guard !data.isEmpty else { return 0 }
        lock.lock()
        guard let s = sessions[handle], s.state == .connected else { lock.unlock(); return -1 }
        let reqId = nextReqId
        nextReqId &+= 1
        let completion = WriteCompletion(ownerHandle: handle)
        pendingWrites[reqId] = completion
        let name = s.deviceName, id = s.deviceIdentifier
        lock.unlock()

        transport.send(.write(deviceName: name, deviceIdentifier: id, reqId: reqId, data: data))

        let written = completion.wait(timeout: writeTimeout)
        lock.lock(); pendingWrites[reqId] = nil; lock.unlock()
        if written == -2 {
            // A stalled write implies the link is gone; drop the session so the
            // Python driver's next `state` poll sees disconnected and retries.
            ExtensionDiagLog.log("[RNODE-NE] write reqId=\(reqId) timed out (\(data.count)B)")
            failSession(name: name, id: id)
        }
        return written
    }

    func setOnline(handle: Int32, online: Bool) -> Int32 {
        lock.lock()
        guard var s = sessions[handle] else { lock.unlock(); return -1 }
        s.online = online
        sessions[handle] = s
        let name = s.deviceName, id = s.deviceIdentifier
        lock.unlock()
        transport.send(.setOnline(deviceName: name, deviceIdentifier: id, online: online))
        return 0
    }

    // MARK: - Inbound app→NE events → local caches

    private func handle(_ msg: RNodeSessionSeamMessage) {
        switch msg {
        case let .stateChanged(name, id, state, reason):
            lock.lock()
            if let h = handleLocked(name: name, id: id), var s = sessions[h] {
                s.state = state
                if state != .connected { s.online = false }
                sessions[h] = s
            }
            lock.unlock()
            ExtensionDiagLog.log("[RNODE-NE] stateChanged '\(name)' -> \(state.rawValue)\(reason.map { " (\($0))" } ?? "")")

        case let .dataReceived(name, id, data):
            lock.lock()
            guard let h = handleLocked(name: name, id: id), var s = sessions[h] else { lock.unlock(); return }
            if s.rxBuffer.count + data.count > maxBufferedBytes {
                // A stalled `read` is the only way this grows; drop the oldest
                // bytes so the KISS deframer does not corrupt on a partial frame.
                s.rxBuffer = Data(data.suffix(maxBufferedBytes / 2))
                s.state = .failed
                s.online = false
                sessions[h] = s
                lock.unlock()
                ExtensionDiagLog.log("[RNODE-NE] rx overflow on '\(name)'; marked failed")
                return
            }
            s.rxBuffer.append(data)
            sessions[h] = s
            lock.unlock()

        case let .writeResult(name, id, reqId, written):
            lock.lock()
            let completion = pendingWrites[reqId]
            lock.unlock()
            if completion == nil {
                // The write already resolved (timeout) or the session closed;
                // the late app reply is discarded.
                ExtensionDiagLog.log("[RNODE-NE] writeResult reqId=\(reqId) dropped (no pending) '\(name)'")
                return
            }
            _ = (id, name)
            completion?.set(written)

        case let .failureChanged(name, id, code):
            lock.lock()
            if let h = handleLocked(name: name, id: id), var s = sessions[h] {
                s.failureCode = code
                sessions[h] = s
            }
            lock.unlock()

        case .open, .close, .write, .setOnline:
            break  // command direction; the forwarder never receives these
        }
    }

    // MARK: - Internals

    /// Look up a live session handle by its (name, id) key. Called under `lock`.
    private func handleLocked(name: String, id: String?) -> Int32? {
        for (h, s) in sessions where s.deviceName == name && s.deviceIdentifier == id { return h }
        return nil
    }

    private func failSession(name: String, id: String?) {
        lock.lock()
        if let h = handleLocked(name: name, id: id), var s = sessions[h] {
            s.state = .failed
            s.online = false
            sessions[h] = s
        }
        lock.unlock()
    }

    /// Allocate a fresh handle. Called under `lock`.
    private func allocateHandleLocked() -> Int32 {
        while nextHandle <= 0 || sessions[nextHandle] != nil {
            nextHandle = nextHandle == Int32.max ? 1 : nextHandle + 1
        }
        let h = nextHandle
        nextHandle = nextHandle == Int32.max ? 1 : nextHandle + 1
        return h
    }

    private static func physicalKey(deviceIdentifier: String?, deviceName: String) -> String {
        let normName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let id = deviceIdentifier, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "id:" + id.lowercased()
        }
        return "name:" + normName
    }
}

// MARK: - C-ABI shims (mirror PythonRNodeBLEBridge.swift symbol-for-symbol)

private func nerrnode_cstr(_ ptr: UnsafePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    return String(cString: ptr)
}

@_used
@_cdecl("columba_rnode_session_open")
public func columba_rnode_session_open(
    _ deviceName: UnsafePointer<CChar>?,
    _ deviceIdentifier: UnsafePointer<CChar>?
) -> Int32 {
    guard let name = nerrnode_cstr(deviceName) else { return -1 }
    let id = nerrnode_cstr(deviceIdentifier)
    return NERNodeCABIBridge.shared.open(deviceName: name, deviceIdentifier: (id?.isEmpty == true ? nil : id))
}

@_cdecl("columba_rnode_session_close")
public func columba_rnode_session_close(_ handle: Int32) -> Int32 {
    NERNodeCABIBridge.shared.close(handle: handle)
}

@_cdecl("columba_rnode_session_state")
public func columba_rnode_session_state(_ handle: Int32) -> Int32 {
    NERNodeCABIBridge.shared.state(handle: handle)
}

@_cdecl("columba_rnode_session_failure")
public func columba_rnode_session_failure(_ handle: Int32) -> Int32 {
    NERNodeCABIBridge.shared.failure(handle: handle)
}

@_cdecl("columba_rnode_session_read")
public func columba_rnode_session_read(
    _ handle: Int32,
    _ output: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int32
) -> Int32 {
    guard let output, capacity > 0 else { return 0 }
    guard let data = NERNodeCABIBridge.shared.read(handle: handle, capacity: capacity) else { return -1 }
    data.copyBytes(to: output, count: data.count)
    return Int32(data.count)
}

@_cdecl("columba_rnode_session_write")
public func columba_rnode_session_write(
    _ handle: Int32,
    _ bytes: UnsafePointer<UInt8>?,
    _ count: Int32
) -> Int32 {
    guard let bytes, count > 0 else { return 0 }
    return NERNodeCABIBridge.shared.write(handle: handle, data: Data(bytes: bytes, count: Int(count)))
}

@_cdecl("columba_rnode_session_set_online")
public func columba_rnode_session_set_online(_ handle: Int32, _ online: Int32) -> Int32 {
    NERNodeCABIBridge.shared.setOnline(handle: handle, online: online != 0)
}
