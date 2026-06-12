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

    // The Transport callbacks are set by `RNodeInterface.setupTransport` (via the KISS
    // wrapper) BEFORE `connect()` runs, so the inbound task — started in `connect()` —
    // reads them without a data race.
    public private(set) var state: TransportState = .disconnected
    public var onStateChange: ((TransportState) -> Void)?
    public var onDataReceived: ((Data) -> Void)?

    /// The RNode device name to target — passed through to the app's `BLETransport`.
    /// Empty string = connect to the first RNode found.
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
            onDataReceived?(data)
        case let .stateChanged(linkState):
            ExtensionDiagLog.log("[RNODE] seam(NE): radio state -> \(linkState)")
            setState(linkState.transportState)
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
        state = newState
        onStateChange?(newState)
    }
}

/// Errors surfaced by the RNode seam transport.
public enum RNodeSeamTransportError: Error {
    /// The seam was torn down with sends still in flight.
    case disconnected
    /// The app-side radio reported a write failure (string carries the underlying error).
    case appWrite(String)
    /// The app-side radio link failed.
    case linkFailed
}

private extension RNodeLinkState {
    var transportState: TransportState {
        switch self {
        case .disconnected: return .disconnected
        case .connecting:   return .connecting
        case .connected:    return .connected
        case .failed:       return .failed(RNodeSeamTransportError.linkFailed)
        }
    }
}
