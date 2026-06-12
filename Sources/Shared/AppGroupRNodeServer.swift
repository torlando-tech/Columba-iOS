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

    private let wire: AppGroupRNodeSeamWire
    private let log: ((String) -> Void)?

    /// App-local mirror of the radio's link-state changes (in addition to forwarding
    /// them to the NE), so the app can surface RNode connection state in its own UI —
    /// the NE owns the authoritative `RNodeInterface`, but the BLE link state is a good
    /// proxy and the app has it directly here.
    public var onLinkStateChange: ((RNodeLinkState) -> Void)?

    private let lock = NSLock()
    private var transport: BLETransport?
    private var transportDeviceName: String?

    private var inboundTask: Task<Void, Never>?

    public init(wire: AppGroupRNodeSeamWire, log: ((String) -> Void)? = nil) {
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

    private func connectRadio(deviceName: String) {
        lock.lock()
        if transport == nil || transportDeviceName != deviceName {
            // (Re)create the radio for this device and wire its callbacks once.
            // BLETransport reuses its CBCentralManager across connect()/disconnect(),
            // so we only rebuild it when the target device changes.
            transport?.disconnect()
            let name = deviceName.isEmpty ? nil : deviceName
            let radio = BLETransport(deviceName: name)
            radio.onDataReceived = { [weak self] data in
                self?.wire.send(.dataReceived(data: data))
            }
            radio.onStateChange = { [weak self] state in
                let link = state.linkState
                self?.log?("[RNODE] server: radio BLE state -> \(link)")
                self?.wire.send(.stateChanged(state: link))
                self?.onLinkStateChange?(link)
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
