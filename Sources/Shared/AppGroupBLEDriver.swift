//
//  AppGroupBLEDriver.swift
//  Shared
//
//  NE side of the Model B BLE seam. The NE runs reticulum-swift's `BLEInterface`,
//  which drives a `BLEDriver`. CoreBluetooth can't run in the NE sandbox, so this
//  driver doesn't touch CoreBluetooth — it **marshals the `BLEDriver` +
//  `BLEPeerConnection` protocol surface across the App-Group** to the app, which
//  runs the real `CoreBluetoothBLEDriver`. Commands go out as
//  `BLEDriverSeamMessage`s; the app's stream events + value-replies come back and
//  are dispatched here (feeding the three driver streams + resuming the
//  reqId-correlated `await`s). See `ble_to_ne_driver_abstraction_plan` (vault).
//
//  Transport-agnostic: takes a `BLESeamTransport` so it's unit-testable with an
//  in-memory loopback. The production transport rides the `a2e`/`e2a`
//  `SharedFrameQueue`s (NE: send→e2a, inbound←a2e).
//

import Foundation
import ReticulumSwift

// `BLESeamTransport` + `BLESeamError` live in BLEDriverSeam.swift (pure Foundation)
// so the concrete `AppGroupBLESeamTransport` can be built/tested without pulling
// in ReticulumSwift.

private extension NSLock {
    func sync<R>(_ body: () -> R) -> R { lock(); defer { unlock() }; return body() }
}

/// `BLEDriver` whose operations are marshaled to the app over a `BLESeamTransport`.
public final class AppGroupBLEDriver: BLEDriver, @unchecked Sendable {

    private let transport: BLESeamTransport
    private let lock = NSLock()

    // Driver streams (fed from app→NE events).
    private let _discoveredPeers: AsyncStream<DiscoveredPeer>
    private let discoveredCont: AsyncStream<DiscoveredPeer>.Continuation
    private let _incomingConnections: AsyncStream<any BLEPeerConnection>
    private let incomingCont: AsyncStream<any BLEPeerConnection>.Continuation
    private let _connectionLost: AsyncStream<String>
    private let connectionLostCont: AsyncStream<String>.Continuation

    // Request/response correlation for the value-returning calls.
    private var nextReqId: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<BLEDriverSeamMessage, Error>] = [:]

    // Live connections, keyed by address — to route inbound fragments + lifecycle.
    private var connections: [String: AppGroupBLEPeerConnection] = [:]

    // Cached local state (the protocol's getters are synchronous; the real values
    // live in the app process, so we cache the last reported snapshot).
    private var cachedLocalAddress: String?
    private var cachedIsRunning = false

    public init(transport: BLESeamTransport) {
        self.transport = transport
        (_discoveredPeers, discoveredCont) = AsyncStream.makeStream(of: DiscoveredPeer.self)
        (_incomingConnections, incomingCont) = AsyncStream.makeStream(of: (any BLEPeerConnection).self)
        (_connectionLost, connectionLostCont) = AsyncStream.makeStream(of: String.self)

        let inbound = transport.inbound
        Task { [weak self] in
            for await message in inbound { self?.handleInbound(message) }
        }
    }

    // MARK: BLEDriver — streams & state

    public var discoveredPeers: AsyncStream<DiscoveredPeer> { _discoveredPeers }
    public var incomingConnections: AsyncStream<any BLEPeerConnection> { _incomingConnections }
    public var connectionLost: AsyncStream<String> { _connectionLost }
    public var localAddress: String? { lock.sync { cachedLocalAddress } }
    public var isRunning: Bool { lock.sync { cachedIsRunning } }

    // MARK: BLEDriver — commands

    public func startAdvertising() async throws { transport.send(.startAdvertising) }
    public func stopAdvertising() async { transport.send(.stopAdvertising) }
    public func startScanning() async throws { transport.send(.startScanning) }
    public func stopScanning() async { transport.send(.stopScanning) }
    public func disconnect(address: String) async { transport.send(.disconnect(address: address)) }
    public func shutdown() { transport.send(.shutdown) }

    public func connect(address: String) async throws -> any BLEPeerConnection {
        let reply = try await request { .connect(reqId: $0, address: address) }
        guard case let .connectResult(_, addr, mtu, identity, error) = reply else {
            throw BLESeamError.unexpectedReply
        }
        if let error { throw BLESeamError.driver(error) }
        return makeConnection(address: addr, mtu: Int(mtu), identity: identity)
    }

    /// Ask the app for the latest local address / running state and cache it.
    public func refreshLocalState() async {
        guard let reply = try? await request({ .queryLocalState(reqId: $0) }),
              case let .queryLocalStateResult(_, addr, running) = reply else { return }
        lock.sync { cachedLocalAddress = addr; cachedIsRunning = running }
    }

    // MARK: Back-channel for AppGroupBLEPeerConnection

    /// Fire-and-forget send on behalf of a connection (sendFragment / writeIdentity / close).
    func connectionSend(_ message: BLEDriverSeamMessage) { transport.send(message) }

    /// reqId round-trip on behalf of a connection (readIdentity / readRemoteRssi).
    func connectionRequest(_ make: (UInt32) -> BLEDriverSeamMessage) async throws -> BLEDriverSeamMessage {
        try await request(make)
    }

    // MARK: Internals

    private func request(_ make: (UInt32) -> BLEDriverSeamMessage) async throws -> BLEDriverSeamMessage {
        let reqId = lock.sync { () -> UInt32 in let r = nextReqId; nextReqId &+= 1; return r }
        return try await withCheckedThrowingContinuation { cont in
            lock.sync { pending[reqId] = cont }
            transport.send(make(reqId))
        }
    }

    private func makeConnection(address: String, mtu: Int, identity: Data?) -> AppGroupBLEPeerConnection {
        let conn = AppGroupBLEPeerConnection(address: address, mtu: mtu, identity: identity, driver: self)
        lock.sync { connections[address] = conn }
        return conn
    }

    private func handleInbound(_ message: BLEDriverSeamMessage) {
        switch message {
        case let .discovered(address, rssi, identity):
            discoveredCont.yield(DiscoveredPeer(address: address, rssi: Int(rssi), identity: identity))

        case let .incomingConnection(address, mtu, identity):
            incomingCont.yield(makeConnection(address: address, mtu: Int(mtu), identity: identity))

        case let .connectionLost(address):
            let conn = lock.sync { connections.removeValue(forKey: address) }
            conn?.finish()
            connectionLostCont.yield(address)

        case let .receivedFragment(address, data):
            let conn = lock.sync { connections[address] }
            conn?.deliver(data)

        case let .queryLocalStateResult(reqId, addr, running):
            lock.sync { cachedLocalAddress = addr; cachedIsRunning = running }
            resume(reqId, with: message)

        case let .connectResult(reqId, _, _, _, _),
             let .readIdentityResult(reqId, _, _),
             let .readRemoteRssiResult(reqId, _, _):
            resume(reqId, with: message)

        default:
            break  // commands never arrive on the NE's inbound channel
        }
    }

    private func resume(_ reqId: UInt32, with message: BLEDriverSeamMessage) {
        let cont = lock.sync { pending.removeValue(forKey: reqId) }
        cont?.resume(returning: message)
    }
}

/// `BLEPeerConnection` whose ops are marshaled to the app via the parent driver.
public final class AppGroupBLEPeerConnection: BLEPeerConnection, @unchecked Sendable {

    public let address: String
    private let lock = NSLock()
    private var cachedMtu: Int
    private var cachedIdentity: Data?
    private unowned let driver: AppGroupBLEDriver

    private let _receivedFragments: AsyncStream<Data>
    private let receivedCont: AsyncStream<Data>.Continuation

    init(address: String, mtu: Int, identity: Data?, driver: AppGroupBLEDriver) {
        self.address = address
        self.cachedMtu = mtu
        self.cachedIdentity = identity
        self.driver = driver
        (_receivedFragments, receivedCont) = AsyncStream.makeStream(of: Data.self)
    }

    public var mtu: Int { lock.sync { cachedMtu } }
    public var identity: Data? { lock.sync { cachedIdentity } }
    public var receivedFragments: AsyncStream<Data> { _receivedFragments }

    public func sendFragment(_ data: Data) async throws {
        driver.connectionSend(.sendFragment(address: address, data: data))
    }

    public func readIdentity() async throws -> Data {
        let reply = try await driver.connectionRequest { .readIdentity(reqId: $0, address: address) }
        guard case let .readIdentityResult(_, identity, error) = reply else { throw BLESeamError.unexpectedReply }
        if let error { throw BLESeamError.driver(error) }
        guard let identity else { throw BLESeamError.driver("no identity") }
        lock.sync { cachedIdentity = identity }
        return identity
    }

    public func writeIdentity(_ identity: Data) async throws {
        driver.connectionSend(.writeIdentity(address: address, identity: identity))
    }

    public func readRemoteRssi() async throws -> Int {
        let reply = try await driver.connectionRequest { .readRemoteRssi(reqId: $0, address: address) }
        guard case let .readRemoteRssiResult(_, rssi, error) = reply else { throw BLESeamError.unexpectedReply }
        if let error { throw BLESeamError.driver(error) }
        return Int(rssi)
    }

    public func close() { driver.connectionSend(.closeConnection(address: address)) }

    // Driver-internal: route inbound fragments + end the stream on disconnect.
    func deliver(_ data: Data) { receivedCont.yield(data) }
    func finish() { receivedCont.finish() }
}
