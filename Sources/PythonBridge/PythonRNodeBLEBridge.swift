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

    init(deviceName: String) {
        transport = BLETransport(deviceName: deviceName)
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
    private let makeTransport: (String) -> PythonRNodeTransporting
    private var transport: PythonRNodeTransporting?
    private var deviceName: String?
    private var inbound = Data()
    private var linkState: PythonRNodeLinkState = .disconnected
    private var failureReason: String?
    private var stateHandler: ((PythonRNodeLinkState, String?) -> Void)?
    private let maxBufferedBytes = 1_048_576

    init(makeTransport: @escaping (String) -> PythonRNodeTransporting = {
        ReticulumPythonRNodeTransport(deviceName: $0)
    }) {
        self.makeTransport = makeTransport
    }

    public func setStateHandler(_ handler: ((PythonRNodeLinkState, String?) -> Void)?) {
        lock.lock()
        stateHandler = handler
        let state = linkState
        let reason = failureReason
        lock.unlock()
        handler?(state, reason)
    }

    public func snapshot() -> (PythonRNodeLinkState, String?) {
        lock.lock(); defer { lock.unlock() }
        return (linkState, failureReason)
    }

    @discardableResult
    public func connect(deviceName requestedName: String) -> Bool {
        let requestedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else { return false }

        lock.lock()
        if deviceName == requestedName, let existing = transport,
           linkState == .connecting || linkState == .connected {
            lock.unlock()
            if linkState == .disconnected { existing.connect() }
            return true
        }
        let old = transport
        let radio = makeTransport(requestedName)
        transport = radio
        deviceName = requestedName
        inbound.removeAll(keepingCapacity: true)
        linkState = .connecting
        failureReason = nil
        radio.onDataReceived = { [weak self] data in self?.receive(data) }
        radio.onStateChange = { [weak self] state, reason in
            self?.update(state: state, reason: reason)
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
        transport = nil
        deviceName = nil
        inbound.removeAll(keepingCapacity: false)
        linkState = .disconnected
        failureReason = nil
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
            return -2
        }
        resultLock.lock(); let error = writeError; resultLock.unlock()
        if let error {
            DiagLog.log("[RNODE_PY] native BLE write failed: \(error.localizedDescription)")
            return -3
        }
        return data.count
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if inbound.count + data.count > maxBufferedBytes {
            let overflow = inbound.count + data.count - maxBufferedBytes
            inbound.removeFirst(min(overflow, inbound.count))
            DiagLog.log("[RNODE_PY] inbound buffer overflow; dropped \(overflow) oldest bytes")
        }
        inbound.append(data)
        lock.unlock()
    }

    private func update(state: PythonRNodeLinkState, reason: String?) {
        lock.lock()
        linkState = state
        failureReason = reason
        let handler = stateHandler
        lock.unlock()
        DiagLog.log("[RNODE_PY] native BLE state=\(state.rawValue) reason=\(reason ?? "none")")
        handler?(state, reason)
    }
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
