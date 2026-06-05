//
//  AppGroupBLEServer.swift
//  Shared
//
//  App side of the Model B BLE seam — the mirror of `AppGroupBLEDriver`. The app
//  hosts the real `BLEDriver` (reticulum-swift's `CoreBluetoothBLEDriver`, since
//  CoreBluetooth can't run in the NE). This server consumes the NE's commands off
//  the seam, drives the local driver, and forwards the driver's three streams +
//  each connection's `receivedFragments` + the reqId-correlated replies back to
//  the NE. Takes `any BLEDriver` so it's driver-agnostic (real CB driver in
//  production; a mock in tests). See `ble_to_ne_driver_abstraction_plan` (vault).
//

import Foundation
import ReticulumSwift

public final class AppGroupBLEServer: @unchecked Sendable {

    private let transport: BLESeamTransport
    private let driver: any BLEDriver
    private let lock = NSLock()
    private var connections: [String: any BLEPeerConnection] = [:]
    /// Optional log sink (the app passes `DiagLog.log`; Shared can't reference it).
    private let log: (@Sendable (String) -> Void)?

    public init(transport: BLESeamTransport, driver: any BLEDriver,
                log: (@Sendable (String) -> Void)? = nil) {
        self.transport = transport
        self.driver = driver
        self.log = log
    }

    /// Begin forwarding the driver's streams to the NE and consuming NE commands.
    public func start() {
        log?("[BLE] server: started — forwarding driver streams over the seam")
        Task { [transport, driver, log] in
            var seenLog = Set<String>()  // log first sighting only (yields fire ~10x/s/peer)
            for await peer in driver.discoveredPeers {
                if seenLog.insert(peer.address).inserted {
                    log?("[BLE] server: discovered \(peer.address.prefix(8)) rssi=\(peer.rssi) → seam")
                }
                transport.send(.discovered(address: peer.address,
                                           rssi: Int16(clamping: peer.rssi),
                                           identity: peer.identity))
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await conn in self.driver.incomingConnections {
                self.log?("[BLE] server: incoming connection \(conn.address.prefix(8)) mtu=\(conn.mtu) → seam")
                self.register(conn)
                self.transport.send(.incomingConnection(address: conn.address,
                                                        mtu: UInt16(clamping: conn.mtu),
                                                        identity: conn.identity))
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await address in self.driver.connectionLost {
                self.log?("[BLE] server: connection lost \(address.prefix(8))")
                self.unregister(address)
                self.transport.send(.connectionLost(address: address))
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await message in self.transport.inbound { await self.handle(message) }
        }
    }

    // MARK: Connection registry + fragment forwarding

    private func register(_ conn: any BLEPeerConnection) {
        let address = conn.address
        lock.sync { connections[address] = conn }
        Task { [transport] in
            for await fragment in conn.receivedFragments {
                transport.send(.receivedFragment(address: address, data: fragment))
            }
        }
    }

    private func unregister(_ address: String) { lock.sync { _ = connections.removeValue(forKey: address) } }
    private func connection(_ address: String) -> (any BLEPeerConnection)? { lock.sync { connections[address] } }

    // MARK: Command dispatch (NE → driver)

    private func handle(_ message: BLEDriverSeamMessage) async {
        switch message {
        case .startAdvertising:
            do { try await driver.startAdvertising(); log?("[BLE] server: startAdvertising OK") }
            catch { log?("[BLE] server: startAdvertising FAILED: \(error)") }
        case .stopAdvertising:  await driver.stopAdvertising()
        case .startScanning:
            do { try await driver.startScanning(); log?("[BLE] server: startScanning OK (localAddr=\(driver.localAddress ?? "nil"))") }
            catch { log?("[BLE] server: startScanning FAILED: \(error)") }
        case .stopScanning:     await driver.stopScanning()
        case .shutdown:         driver.shutdown()
        case let .disconnect(address): await driver.disconnect(address: address)

        case let .connect(reqId, address):
            log?("[BLE] server: connect → \(address.prefix(8)) (central)")
            do {
                let conn = try await driver.connect(address: address)
                log?("[BLE] server: connect OK \(address.prefix(8)) mtu=\(conn.mtu)")
                register(conn)
                transport.send(.connectResult(reqId: reqId, address: conn.address,
                                              mtu: UInt16(clamping: conn.mtu),
                                              identity: conn.identity, error: nil))
            } catch {
                log?("[BLE] server: connect FAILED \(address.prefix(8)): \(error)")
                transport.send(.connectResult(reqId: reqId, address: address, mtu: 0,
                                              identity: nil, error: String(describing: error)))
            }

        case let .queryLocalState(reqId):
            transport.send(.queryLocalStateResult(reqId: reqId,
                                                  localAddress: driver.localAddress,
                                                  isRunning: driver.isRunning))

        case let .sendFragment(address, data):
            try? await connection(address)?.sendFragment(data)

        case let .writeIdentity(address, identity):
            log?("[BLE] server: writeIdentity → \(address.prefix(8)) (\(identity.count)B)")
            do { try await connection(address)?.writeIdentity(identity); log?("[BLE] server: writeIdentity OK \(address.prefix(8))") }
            catch { log?("[BLE] server: writeIdentity FAILED \(address.prefix(8)): \(error)") }

        case let .closeConnection(address):
            connection(address)?.close()
            unregister(address)

        case let .readIdentity(reqId, address):
            log?("[BLE] server: readIdentity → \(address.prefix(8))")
            guard let conn = connection(address) else {
                log?("[BLE] server: readIdentity NO-CONN \(address.prefix(8))")
                transport.send(.readIdentityResult(reqId: reqId, identity: nil, error: "no connection")); return
            }
            do {
                let id = try await conn.readIdentity()
                log?("[BLE] server: readIdentity OK \(address.prefix(8)) (\(id.count)B)")
                transport.send(.readIdentityResult(reqId: reqId, identity: id, error: nil))
            } catch {
                log?("[BLE] server: readIdentity FAILED \(address.prefix(8)): \(error)")
                transport.send(.readIdentityResult(reqId: reqId, identity: nil, error: String(describing: error)))
            }

        case let .readRemoteRssi(reqId, address):
            guard let conn = connection(address) else {
                transport.send(.readRemoteRssiResult(reqId: reqId, rssi: 0, error: "no connection")); return
            }
            do { transport.send(.readRemoteRssiResult(reqId: reqId, rssi: Int16(clamping: try await conn.readRemoteRssi()), error: nil)) }
            catch { transport.send(.readRemoteRssiResult(reqId: reqId, rssi: 0, error: String(describing: error))) }

        default:
            break  // results/events flow app→NE; the server never receives them
        }
    }
}

private extension NSLock {
    func sync<R>(_ body: () -> R) -> R { lock(); defer { unlock() }; return body() }
}
