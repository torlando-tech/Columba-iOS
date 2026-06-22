//
//  AppGroupRNodeSeamTransport.swift
//  Shared
//
//  NE-side reticulum-swift `Transport` for the Model B RNode seam. Marshals the
//  `Transport` surface (connect / send / disconnect / state / onDataReceived) across
//  the App-Group to the app's real `BLETransport` over an `RNodeSeamWire`. Injected
//  into `RNodeInterface` via its `transportFactory`, replacing the direct-CoreBluetooth
//  `BLETransport` — so the radio runs in the app process (Model B) while
//  `RNodeInterface` + KISS framing run here in the NE.
//
//  Mirrors how `AppGroupBLEDriver` marshals the `BLEDriver` surface for the BLE mesh,
//  but tiny: RNode is a single serial stream. `send` carries a `reqId` so the NE's
//  `send(_:completion:)` resumes only when the app's real write completes — RNode flow
//  control depends on write-completion (`RNodeInterface.sendViaTransport`).
//

import Foundation
import ReticulumSwift

public final class AppGroupRNodeSeamTransport: Transport, @unchecked Sendable {

    private let wire: AppGroupRNodeSeamWire
    private var inboundTask: Task<Void, Never>?

    private let lock = NSLock()
    private var pendingSends: [UInt32: (Error?) -> Void] = [:]
    private var nextReqId: UInt32 = 0

    // The Transport callbacks are normally set by `RNodeInterface.setupTransport` (via the
    // KISS wrapper) BEFORE `connect()`, but `RNodeInterface.attemptReconnect` nils them on
    // the interface actor WHILE the inbound task is still delivering, so reads/writes race.
    // Guard `state`/`onStateChange`/`onDataReceived` with the same `lock` as `pendingSends`
    // (never held across a callback, so no re-entrancy/deadlock).
    private var _state: TransportState = .disconnected
    public var state: TransportState {
        lock.lock(); defer { lock.unlock() }; return _state
    }
    private var _onStateChange: ((TransportState) -> Void)?
    public var onStateChange: ((TransportState) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStateChange }
        set { lock.lock(); _onStateChange = newValue; lock.unlock() }
    }
    private var _onDataReceived: ((Data) -> Void)?
    public var onDataReceived: ((Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onDataReceived }
        set { lock.lock(); _onDataReceived = newValue; lock.unlock() }
    }

    /// The RNode device name to target — passed through to the app's `BLETransport`.
    /// Must be non-empty; `AppGroupRNodeServer.connectRadio` rejects an empty name
    /// (it would drop the radio into scan-only mode with no connect and no timeout).
    private let deviceName: String

    public init(
        deviceName: String,
        wire: AppGroupRNodeSeamWire = AppGroupRNodeSeamWire(role: .networkExtension)
    ) {
        self.deviceName = deviceName
        self.wire = wire
    }

    // MARK: - Transport

    public func connect() {
        ExtensionDiagLog.log("[RNODE] seam(NE): connect(device='\(deviceName)')")
        inboundTask = Task { [weak self] in
            guard let self else { return }
            for await message in self.wire.inbound {
                self.handle(message)
            }
        }
        wire.start()
        setState(.connecting)
        wire.send(.connect(deviceName: deviceName))
    }

    public func send(_ data: Data, completion: ((Error?) -> Void)?) {
        lock.lock()
        let reqId = nextReqId
        nextReqId &+= 1
        if let completion { pendingSends[reqId] = completion }
        lock.unlock()
        wire.send(.send(reqId: reqId, data: data))

        // Liveness watchdog: if the app-side radio never returns a `.sendResult` — a lost
        // frame, or the app process suspended/jettisoned mid-write — the awaiting `send`
        // continuation would hang and `RNodeInterface` stays `interfaceReady=false`, wedging
        // all outbound TX silently. After 8s (≫ normal write latency) fail the pending send
        // and drive `.disconnected`, which routes through `handleTransportStateChange` to
        // reset readiness and restart the NE-local reconnect (it does NOT send `.disconnect`
        // over the wire, so the app-side shared radio is untouched and reconnect re-issues
        // `.connect` idempotently). The real `.sendResult` arriving first removes the reqId,
        // making this a no-op.
        guard completion != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)  // 8s
            guard let self else { return }
            self.lock.lock()
            let timedOut = self.pendingSends.removeValue(forKey: reqId)
            self.lock.unlock()
            if let timedOut {
                ExtensionDiagLog.log("[RNODE] seam(NE): send reqId=\(reqId) timed out")
                timedOut(RNodeSeamTransportError.appWrite("seam send timeout"))
                self.setState(.disconnected)
            }
        }
    }

    public func disconnect() {
        ExtensionDiagLog.log("[RNODE] seam(NE): disconnect")
        wire.send(.disconnect)
        inboundTask?.cancel()
        inboundTask = nil
        wire.stop()
        // Fail any in-flight sends so the awaiting `send` continuations don't hang.
        lock.lock()
        let pending = pendingSends
        pendingSends.removeAll()
        lock.unlock()
        for (_, completion) in pending { completion(RNodeSeamTransportError.disconnected) }
        setState(.disconnected)
    }

    // MARK: - Inbound (app → NE)

    private func handle(_ message: RNodeSeamMessage) {
        switch message {
        case let .dataReceived(data):
            lock.lock(); let cb = _onDataReceived; lock.unlock()
            cb?(data)
        case let .stateChanged(linkState, reason):
            ExtensionDiagLog.log("[RNODE] seam(NE): radio state -> \(linkState)\(reason.map { " (\($0))" } ?? "")")
            setState(linkState.transportState(reason: reason))
        case let .sendResult(reqId, error):
            lock.lock()
            let completion = pendingSends.removeValue(forKey: reqId)
            lock.unlock()
            completion?(error.map { RNodeSeamTransportError.appWrite($0) })
        case .connect, .send, .disconnect:
            break  // NE→app commands; the NE never receives these inbound.
        }
    }

    private func setState(_ newState: TransportState) {
        lock.lock(); _state = newState; let cb = _onStateChange; lock.unlock()
        cb?(newState)
    }
}

/// Errors surfaced by the RNode seam transport.
public enum RNodeSeamTransportError: Error {
    /// The seam was torn down with sends still in flight.
    case disconnected
    /// The app-side radio reported a write failure (string carries the underlying error).
    case appWrite(String)
    /// The app-side radio link failed (string carries the underlying reason, if any).
    case linkFailed(String?)
}

private extension RNodeLinkState {
    func transportState(reason: String?) -> TransportState {
        switch self {
        case .disconnected: return .disconnected
        case .connecting:   return .connecting
        case .connected:    return .connected
        case .failed:       return .failed(RNodeSeamTransportError.linkFailed(reason))
        }
    }
}
