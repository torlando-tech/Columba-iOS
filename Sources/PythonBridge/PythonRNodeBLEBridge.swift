//
//  PythonRNodeBLEBridge.swift
//  ColumbaApp (shipping Python runtime only)
//
//  Native CoreBluetooth/NUS byte-stream owner for IOSRNodeInterface.py. The
//  Python side owns RNS, KISS framing and radio configuration; this bridge owns
//  ReticulumSwift.BLETransport and exposes a small synchronous C ABI to ctypes.
//

import Foundation
import ReticulumSwift

public enum PythonRNodeLinkState: Int32, Sendable {
    case disconnected = 0
    case connecting = 1
    case connected = 2
    case failed = 3
}

protocol PythonRNodeTransporting: AnyObject {
    var onDataReceived: ((Data) -> Void)? { get set }
    var onStateChange: ((PythonRNodeLinkState, String?) -> Void)? { get set }
    func connect()
    func disconnect()
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
}

private final class ReticulumPythonRNodeTransport: PythonRNodeTransporting {
    private let transport: BLETransport
    var onDataReceived: ((Data) -> Void)? {
        didSet { transport.onDataReceived = onDataReceived }
    }
    var onStateChange: ((PythonRNodeLinkState, String?) -> Void)?

    init(deviceName: String, deviceIdentifier: UUID?, restorationIdentifier: String? = nil) {
        transport = BLETransport(
            deviceName: deviceName,
            deviceIdentifier: deviceIdentifier,
            restorationIdentifier: restorationIdentifier ?? BLEConstants.RESTORE_IDENTIFIER_KEY
        )
        transport.onStateChange = { [weak self] state in
            let mapped: PythonRNodeLinkState
            let reason: String?
            switch state {
            case .disconnected:
                mapped = .disconnected
                reason = nil
            case .connecting:
                mapped = .connecting
                reason = nil
            case .connected:
                mapped = .connected
                reason = nil
            case .failed(let error):
                mapped = .failed
                reason = error.localizedDescription
            }
            self?.onStateChange?(mapped, reason)
        }
    }

    func connect() { transport.connect() }
    func disconnect() { transport.disconnect() }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        transport.send(data, completion: completion)
    }
}

public final class PythonRNodeBLEBridge: @unchecked Sendable {
    public static let shared = PythonRNodeBLEBridge()

    private let lock = NSLock()
    private let makeTransport: (String, UUID?) -> PythonRNodeTransporting
    private var transport: PythonRNodeTransporting?
    private var deviceName: String?
    private var inbound = Data()
    private var linkState: PythonRNodeLinkState = .disconnected
    private var failureReason: String?
    private var stateHandler: ((PythonRNodeLinkState, String?) -> Void)?
    private var generation: UInt64 = 0
    private var interfaceOnline = false
    private let maxBufferedBytes = 1_048_576

    init(makeTransport: @escaping (String, UUID?) -> PythonRNodeTransporting = {
        ReticulumPythonRNodeTransport(deviceName: $0, deviceIdentifier: $1)
    }) {
        self.makeTransport = makeTransport
    }

    public func setStateHandler(_ handler: ((PythonRNodeLinkState, String?) -> Void)?) {
        lock.lock()
        stateHandler = handler
        let state = publishedStateLocked()
        let reason = failureReason
        lock.unlock()
        handler?(state, reason)
    }

    public func snapshot() -> (PythonRNodeLinkState, String?) {
        lock.lock(); defer { lock.unlock() }
        return (linkState, failureReason)
    }

    /// RNS calls this only after RNode detection and radio configuration finish.
    /// Native BLE `.connected` alone is not proof that the interface is usable.
    public func setInterfaceOnline(_ online: Bool) {
        lock.lock()
        interfaceOnline = online
        let state = publishedStateLocked()
        let reason = failureReason
        let handler = stateHandler
        lock.unlock()
        handler?(state, reason)
    }

    @discardableResult
    public func connect(deviceName requestedName: String, deviceIdentifier: UUID? = nil) -> Bool {
        let requestedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else { return false }

        lock.lock()
        if transport != nil,
           linkState == .connecting || linkState == .connected {
            let activeName = deviceName ?? "unknown"
            lock.unlock()
            DiagLog.log("[RNODE_PY] rejected duplicate RNode interface '\(requestedName)' while '\(activeName)' owns the byte stream")
            return false
        }
        let old = transport
        let radio = makeTransport(requestedName, deviceIdentifier)
        generation &+= 1
        let currentGeneration = generation
        transport = radio
        deviceName = requestedName
        inbound.removeAll(keepingCapacity: true)
        linkState = .connecting
        failureReason = nil
        interfaceOnline = false
        radio.onDataReceived = { [weak self] data in
            self?.receive(data, generation: currentGeneration)
        }
        radio.onStateChange = { [weak self] state, reason in
            self?.update(state: state, reason: reason, generation: currentGeneration)
        }
        let handler = stateHandler
        lock.unlock()

        old?.disconnect()
        handler?(.connecting, nil)
        DiagLog.log("[RNODE_PY] native BLE connect requested for '\(requestedName)'")
        radio.connect()
        return true
    }

    public func disconnect() {
        lock.lock()
        let radio = transport
        generation &+= 1
        transport = nil
        deviceName = nil
        inbound.removeAll(keepingCapacity: false)
        linkState = .disconnected
        failureReason = nil
        interfaceOnline = false
        let handler = stateHandler
        lock.unlock()
        radio?.disconnect()
        handler?(.disconnected, nil)
        DiagLog.log("[RNODE_PY] native BLE disconnected")
    }

    public func read(maxBytes: Int) -> Data {
        guard maxBytes > 0 else { return Data() }
        lock.lock(); defer { lock.unlock() }
        let count = min(maxBytes, inbound.count)
        guard count > 0 else { return Data() }
        let output = inbound.prefix(count)
        inbound.removeFirst(count)
        return Data(output)
    }

    public func writeSync(_ data: Data, timeout: TimeInterval = 10) -> Int {
        guard !data.isEmpty else { return 0 }
        lock.lock()
        let radio = transport
        let connected = linkState == .connected
        let writeGeneration = generation
        lock.unlock()
        guard connected, let radio else { return -1 }

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var writeError: Error?
        radio.send(data) { error in
            resultLock.lock(); writeError = error; resultLock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            DiagLog.log("[RNODE_PY] native BLE write timed out (\(data.count)B)")
            disconnectIfCurrent(radio, generation: writeGeneration)
            return -2
        }
        resultLock.lock(); let error = writeError; resultLock.unlock()
        if let error {
            DiagLog.log("[RNODE_PY] native BLE write failed: \(error.localizedDescription)")
            disconnectIfCurrent(radio, generation: writeGeneration)
            return -3
        }
        lock.lock()
        let stillCurrent = generation == writeGeneration && linkState == .connected
        lock.unlock()
        return stillCurrent ? data.count : -4
    }

    /// Tear down a failed write only if it still belongs to the transport that
    /// issued it. A reconnect may install a replacement while the old async
    /// completion is outstanding; that stale completion must not kill the new
    /// session.
    private func disconnectIfCurrent(
        _ expectedTransport: PythonRNodeTransporting,
        generation expectedGeneration: UInt64
    ) {
        lock.lock()
        guard generation == expectedGeneration, transport === expectedTransport else {
            lock.unlock()
            return
        }
        generation &+= 1
        transport = nil
        deviceName = nil
        inbound.removeAll(keepingCapacity: false)
        linkState = .disconnected
        failureReason = nil
        interfaceOnline = false
        let handler = stateHandler
        lock.unlock()
        expectedTransport.disconnect()
        handler?(.disconnected, nil)
    }

    private func receive(_ data: Data, generation callbackGeneration: UInt64) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard generation == callbackGeneration else {
            lock.unlock()
            return
        }
        if inbound.count + data.count > maxBufferedBytes {
            inbound.removeAll(keepingCapacity: false)
            linkState = .failed
            failureReason = "RNode inbound buffer overflow"
            interfaceOnline = false
            generation &+= 1
            let radio = transport
            transport = nil
            deviceName = nil
            let handler = stateHandler
            lock.unlock()
            radio?.disconnect()
            DiagLog.log("[RNODE_PY] inbound overflow; disconnected to preserve KISS framing")
            handler?(.failed, "RNode inbound buffer overflow")
            return
        }
        inbound.append(data)
        lock.unlock()
    }

    private func update(
        state: PythonRNodeLinkState,
        reason: String?,
        generation callbackGeneration: UInt64
    ) {
        lock.lock()
        guard generation == callbackGeneration else {
            lock.unlock()
            return
        }
        linkState = state
        failureReason = reason
        if state != .connected { interfaceOnline = false }
        let publishedState = publishedStateLocked()
        let handler = stateHandler
        lock.unlock()
        DiagLog.log("[RNODE_PY] native BLE state=\(state.rawValue) reason=\(reason ?? "none")")
        handler?(publishedState, reason)
    }

    private func publishedStateLocked() -> PythonRNodeLinkState {
        linkState == .connected && !interfaceOnline ? .connecting : linkState
    }
}

/// Process-wide owner of independent Python RNode byte-stream sessions.
///
/// A claim is keyed by CoreBluetooth's stable peripheral UUID when available,
/// falling back to the normalized advertised name for legacy configurations.
/// This permits concurrent sessions for different physical RNodes while making
/// a second claim for the same peripheral fail atomically.
final class PythonRNodeBLESessionRegistry: @unchecked Sendable {
    static let shared = PythonRNodeBLESessionRegistry()

    private struct Session {
        let physicalKey: String
        let bridge: PythonRNodeBLEBridge
    }

    private let lock = NSLock()
    private let makeTransport: (String, UUID?) -> PythonRNodeTransporting
    private var sessions: [Int32: Session] = [:]
    private var claims: [String: Int32] = [:]
    private var nextHandle: Int32 = 1

    init(makeTransport: @escaping (String, UUID?) -> PythonRNodeTransporting = {
        let stableComponent = $1?.uuidString.lowercased()
            ?? String($0.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return ReticulumPythonRNodeTransport(
            deviceName: $0,
            deviceIdentifier: $1,
            restorationIdentifier: "com.columba.ble.rnode.session.\(stableComponent)"
        )
    }) {
        self.makeTransport = makeTransport
    }

    @discardableResult
    func open(deviceName rawName: String, deviceIdentifier rawIdentifier: String?) -> Int32 {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return -1 }

        let identifier: UUID?
        if let rawIdentifier,
           !rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = UUID(uuidString: rawIdentifier) else { return -3 }
            identifier = parsed
        } else {
            identifier = nil
        }
        let physicalKey = Self.physicalKey(deviceIdentifier: identifier, deviceName: name)

        lock.lock()
        let hasLegacyClaim = claims.keys.contains { $0.hasPrefix("name:") }
        if (identifier == nil && !sessions.isEmpty) || (identifier != nil && hasLegacyClaim) {
            lock.unlock()
            DiagLog.log("[RNODE_PY] rejected ambiguous legacy RNode claim for '\(name)'")
            return -1
        }
        guard claims[physicalKey] == nil else {
            lock.unlock()
            DiagLog.log("[RNODE_PY] rejected duplicate physical RNode claim '\(physicalKey)'")
            return -2
        }
        let handle = allocateHandleLocked()
        let bridge = PythonRNodeBLEBridge(makeTransport: makeTransport)
        sessions[handle] = Session(physicalKey: physicalKey, bridge: bridge)
        claims[physicalKey] = handle
        lock.unlock()

        guard bridge.connect(deviceName: name, deviceIdentifier: identifier) else {
            _ = close(handle: handle)
            return -4
        }
        DiagLog.log("[RNODE_PY] opened session \(handle) for '\(name)' key='\(physicalKey)'")
        return handle
    }

    @discardableResult
    func close(handle: Int32) -> Bool {
        lock.lock()
        guard let session = sessions.removeValue(forKey: handle) else {
            lock.unlock()
            return false
        }
        if claims[session.physicalKey] == handle {
            claims.removeValue(forKey: session.physicalKey)
        }
        lock.unlock()
        session.bridge.disconnect()
        DiagLog.log("[RNODE_PY] closed session \(handle)")
        return true
    }

    func closeAll() {
        lock.lock()
        let current = Array(sessions.values)
        sessions.removeAll(keepingCapacity: false)
        claims.removeAll(keepingCapacity: false)
        lock.unlock()
        for session in current {
            session.bridge.disconnect()
        }
        DiagLog.log("[RNODE_PY] closed all sessions (\(current.count))")
    }

    func snapshot(handle: Int32) -> (PythonRNodeLinkState, String?)? {
        bridge(handle: handle)?.snapshot()
    }

    func snapshot(
        deviceIdentifier: UUID?,
        deviceName: String
    ) -> (PythonRNodeLinkState, String?)? {
        let key = Self.physicalKey(
            deviceIdentifier: deviceIdentifier,
            deviceName: deviceName
        )
        lock.lock()
        let bridge = claims[key].flatMap { sessions[$0]?.bridge }
        lock.unlock()
        return bridge?.snapshot()
    }

    func read(handle: Int32, maxBytes: Int) -> Data? {
        bridge(handle: handle)?.read(maxBytes: maxBytes)
    }

    func write(handle: Int32, data: Data) -> Int {
        bridge(handle: handle)?.writeSync(data) ?? -1
    }

    @discardableResult
    func setInterfaceOnline(handle: Int32, online: Bool) -> Bool {
        guard let bridge = bridge(handle: handle) else { return false }
        bridge.setInterfaceOnline(online)
        return true
    }

    var activeSessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    private func bridge(handle: Int32) -> PythonRNodeBLEBridge? {
        lock.lock(); defer { lock.unlock() }
        return sessions[handle]?.bridge
    }

    private func allocateHandleLocked() -> Int32 {
        while nextHandle <= 0 || sessions[nextHandle] != nil {
            nextHandle = nextHandle == Int32.max ? 1 : nextHandle + 1
        }
        let handle = nextHandle
        nextHandle = nextHandle == Int32.max ? 1 : nextHandle + 1
        return handle
    }

    private static func physicalKey(deviceIdentifier: UUID?, deviceName: String) -> String {
        deviceIdentifier.map { "id:\($0.uuidString.lowercased())" }
            ?? "name:\(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}

@_cdecl("columba_rnode_session_open")
public func columba_rnode_session_open(
    _ deviceName: UnsafePointer<CChar>?,
    _ deviceIdentifier: UnsafePointer<CChar>?
) -> Int32 {
    guard let deviceName else { return -1 }
    return PythonRNodeBLESessionRegistry.shared.open(
        deviceName: String(cString: deviceName),
        deviceIdentifier: deviceIdentifier.map { String(cString: $0) }
    )
}

@_cdecl("columba_rnode_session_close")
public func columba_rnode_session_close(_ handle: Int32) -> Int32 {
    PythonRNodeBLESessionRegistry.shared.close(handle: handle) ? 0 : -1
}

@_cdecl("columba_rnode_session_state")
public func columba_rnode_session_state(_ handle: Int32) -> Int32 {
    PythonRNodeBLESessionRegistry.shared.snapshot(handle: handle)?.0.rawValue
        ?? PythonRNodeLinkState.disconnected.rawValue
}

@_cdecl("columba_rnode_session_read")
public func columba_rnode_session_read(
    _ handle: Int32,
    _ output: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int32
) -> Int32 {
    guard let output, capacity > 0 else { return 0 }
    guard let data = PythonRNodeBLESessionRegistry.shared.read(
        handle: handle,
        maxBytes: Int(capacity)
    ) else { return -1 }
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
    return Int32(PythonRNodeBLESessionRegistry.shared.write(
        handle: handle,
        data: Data(bytes: bytes, count: Int(count))
    ))
}

@_cdecl("columba_rnode_session_set_online")
public func columba_rnode_session_set_online(_ handle: Int32, _ online: Int32) -> Int32 {
    PythonRNodeBLESessionRegistry.shared.setInterfaceOnline(
        handle: handle,
        online: online != 0
    ) ? 0 : -1
}

@_cdecl("columba_rnode_connect")
public func columba_rnode_connect(_ deviceName: UnsafePointer<CChar>?) -> Int32 {
    guard let deviceName else { return -1 }
    return PythonRNodeBLEBridge.shared.connect(deviceName: String(cString: deviceName)) ? 0 : -2
}

@_cdecl("columba_rnode_disconnect")
public func columba_rnode_disconnect() -> Int32 {
    PythonRNodeBLEBridge.shared.disconnect()
    return 0
}

@_cdecl("columba_rnode_state")
public func columba_rnode_state() -> Int32 {
    PythonRNodeBLEBridge.shared.snapshot().0.rawValue
}

@_cdecl("columba_rnode_read")
public func columba_rnode_read(_ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int32) -> Int32 {
    guard let output, capacity > 0 else { return 0 }
    let data = PythonRNodeBLEBridge.shared.read(maxBytes: Int(capacity))
    data.copyBytes(to: output, count: data.count)
    return Int32(data.count)
}

@_cdecl("columba_rnode_write")
public func columba_rnode_write(_ bytes: UnsafePointer<UInt8>?, _ count: Int32) -> Int32 {
    guard let bytes, count > 0 else { return 0 }
    return Int32(PythonRNodeBLEBridge.shared.writeSync(Data(bytes: bytes, count: Int(count))))
}

@_cdecl("columba_rnode_set_online")
public func columba_rnode_set_online(_ online: Int32) -> Int32 {
    PythonRNodeBLEBridge.shared.setInterfaceOnline(online != 0)
    return 0
}
