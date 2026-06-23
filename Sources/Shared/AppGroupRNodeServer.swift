//
//  AppGroupRNodeServer.swift
//  Shared
//
//  App-side server for the Model B RNode seam. Owns the real CoreBluetooth RNode radio
//  (reticulum-swift `BLETransport`: NUS scan, MTU chunking, write backpressure,
//  background state) and drives it from NE commands arriving over an `RNodeSeamWire`,
//  forwarding received serial bytes + radio state-changes back to the NE.
//
//  The app-side counterpart to `AppGroupRNodeSeamTransport`. Mirrors `AppGroupBLEServer`
//  for the BLE mesh, but tiny — one serial stream, no per-peer addressing.
//

import Foundation
import ReticulumSwift

public final class AppGroupRNodeServer: @unchecked Sendable {

    private let wire: RNodeSeamWire
    private let log: ((String) -> Void)?

    /// App-local mirror of the radio's link-state changes (in addition to forwarding
    /// them to the NE), so the app can surface RNode connection state in its own UI —
    /// the NE owns the authoritative `RNodeInterface`, but the BLE link state is a good
    /// proxy and the app has it directly here.
    public var onLinkStateChange: ((RNodeLinkState, String?) -> Void)?

    private let lock = NSLock()
    private var transport: BLETransport?
    private var transportDeviceName: String?

    private var inboundTask: Task<Void, Never>?

    public init(wire: RNodeSeamWire, log: ((String) -> Void)? = nil) {
        self.wire = wire
        self.log = log
    }

    /// Begin observing the seam + serving NE commands. Call once after construction.
    public func start() {
        wire.start()
        inboundTask = Task { [weak self] in
            guard let self else { return }
            for await message in self.wire.inbound {
                self.handle(message)
            }
        }
    }

    public func stop() {
        inboundTask?.cancel()
        inboundTask = nil
        lock.lock()
        let t = transport
        transport = nil
        transportDeviceName = nil
        lock.unlock()
        t?.disconnect()
        wire.stop()
    }

    // MARK: - NE → app commands

    private func handle(_ message: RNodeSeamMessage) {
        switch message {
        case let .connect(deviceName):
            connectRadio(deviceName: deviceName)
        case let .send(reqId, data):
            sendToRadio(reqId: reqId, data: data)
        case .disconnect:
            lock.lock(); let t = transport; lock.unlock()
            log?("[RNODE] server: disconnect radio")
            t?.disconnect()
        case .dataReceived, .stateChanged, .sendResult:
            break  // app→NE events; the app never receives these inbound.
        }
    }

    /// Re-create + connect the radio at app launch from the persisted device name (for
    /// CoreBluetooth state restoration / background relaunch). Idempotent with the
    /// NE-driven `.connect`: the per-deviceName transport cache means a later `.connect`
    /// reuses this same central rather than creating a second one with the same restore id.
    public func restoreRadio(deviceName: String) {
        connectRadio(deviceName: deviceName)
    }

    private func connectRadio(deviceName: String) {
        // An empty name would drop BLETransport into scan-only mode (no auto-connect, no
        // timeout) and wedge the UI on "connecting" forever. The UI already requires a
        // device name; refuse defensively and surface a failure rather than entering that
        // dead mode. (RNode targets a specific device by name — there is no "first found".)
        guard !deviceName.isEmpty else {
            log?("[RNODE] server: refusing connect with empty deviceName")
            wire.send(.stateChanged(state: .failed, reason: "No RNode device selected"))
            return
        }
        lock.lock()
        if transport == nil || transportDeviceName != deviceName {
            // (Re)create the radio for this device and wire its callbacks once.
            // BLETransport reuses its CBCentralManager across connect()/disconnect(),
            // so we only rebuild it when the target device changes.
            transport?.disconnect()
            let radio = BLETransport(deviceName: deviceName)
            radio.onDataReceived = { [weak self] data in
                self?.wire.send(.dataReceived(data: data))
            }
            radio.onStateChange = { [weak self] state in
                let link = state.linkState
                // Preserve the underlying failure reason (BLEError copy) for the NE/UI.
                var reason: String? = nil
                if case .failed(let err) = state { reason = err.localizedDescription }
                self?.log?("[RNODE] server: radio BLE state -> \(link)")
                self?.wire.send(.stateChanged(state: link, reason: reason))
                self?.onLinkStateChange?(link, reason)
            }
            transport = radio
            transportDeviceName = deviceName
        }
        let radio = transport
        lock.unlock()
        log?("[RNODE] server: connect radio '\(deviceName)'")
        radio?.connect()
    }

    private func sendToRadio(reqId: UInt32, data: Data) {
        lock.lock(); let radio = transport; lock.unlock()
        guard let radio else {
            wire.send(.sendResult(reqId: reqId, error: "rnode radio not connected"))
            return
        }
        radio.send(data) { [weak self] error in
            if let error { self?.log?("[RNODE] server: send reqId=\(reqId) \(data.count)B FAILED: \(error.localizedDescription)") }
            self?.wire.send(.sendResult(reqId: reqId, error: error?.localizedDescription))
        }
    }
}

private extension TransportState {
    var linkState: RNodeLinkState {
        switch self {
        case .disconnected: return .disconnected
        case .connecting:   return .connecting
        case .connected:    return .connected
        case .failed:       return .failed
        }
    }
}
