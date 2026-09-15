//
//  PythonConfigWriterTests.swift
//  ColumbaAppTests
//
//  Regression coverage for the RNS config text emitted by PythonConfigWriter.
//  Guards the crash-on-launch bug where placeholder interfaces
//  emitted `enabled` twice in one section (`enabled = yes` from the shared
//  header + `enabled = no` from the per-type block) — RNS's configobj rejects a
//  duplicate keyword with a DuplicateError, so the Python backend failed to
//  start and the app terminated on launch.
//

import XCTest
import RNSAPI
import CoreBluetooth
@testable import ColumbaApp

final class PythonConfigWriterTests: XCTestCase {

    /// Count `enabled = …` lines (excluding `interface_enabled`) inside the
    /// single interface section of a one-interface config.
    private func enabledLines(_ config: String) -> [String] {
        config
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("enabled =") }
    }

    func testRNodeEmitsEnabledNativeBridgeAndRadioParameters() {
        var rnode = RNodeConfig()
        rnode.deviceName = "RNode 1234"
        rnode.deviceIdentifier = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        rnode.frequency = 915_000_000
        rnode.bandwidth = 125_000
        rnode.txPower = 17
        rnode.spreadingFactor = 8
        rnode.codingRate = 6
        rnode.stAlock = 2.5
        rnode.ltAlock = 1.0
        let iface = InterfaceEntity(
            name: "RNode Radio",
            type: .rnode,
            config: .rnode(rnode)
        )
        let config = PythonConfigWriter.write(interfaces: [iface])

        XCTAssertEqual(enabledLines(config), ["enabled = yes"])
        XCTAssertTrue(config.contains("type = IOSRNodeInterface"))
        XCTAssertTrue(config.contains("connection_mode = ble"))
        XCTAssertTrue(config.contains("target_device_name = RNode 1234"))
        XCTAssertTrue(config.contains("target_device_identifier = AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        XCTAssertTrue(config.contains("frequency = 915000000"))
        XCTAssertTrue(config.contains("bandwidth = 125000"))
        XCTAssertTrue(config.contains("txpower = 17"))
        XCTAssertTrue(config.contains("spreadingfactor = 8"))
        XCTAssertTrue(config.contains("codingrate = 6"))
        XCTAssertTrue(config.contains("st_alock = 2.5"))
        XCTAssertTrue(config.contains("lt_alock = 1.0"))
    }

    func testMultipeerPlaceholderEmitsEnabledExactlyOnceAndDisabled() {
        let iface = InterfaceEntity(
            name: "Multipeer",
            type: .multipeer,
            config: .multipeer(MultipeerConfig())
        )
        let config = PythonConfigWriter.write(interfaces: [iface])

        XCTAssertEqual(enabledLines(config), ["enabled = no"],
                       "Multipeer placeholder must emit `enabled` exactly once, disabled\n\(config)")
    }

    func testRealInterfaceEmitsEnabledExactlyOnceAndEnabled() {
        let iface = InterfaceEntity(
            name: "kin",
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(targetHost: "rns.kin.earth", targetPort: 4242))
        )
        let config = PythonConfigWriter.write(interfaces: [iface])

        XCTAssertEqual(enabledLines(config), ["enabled = yes"],
                       "A real interface must emit `enabled = yes` exactly once\n\(config)")
    }

    func testDiscoveryConfigKeysEmitEnabledValues() {
        let iface = InterfaceEntity(
            name: "kin",
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(targetHost: "rns.kin.earth", targetPort: 4242))
        )
        let config = PythonConfigWriter.write(
            interfaces: [iface],
            discoverInterfaces: true,
            autoconnectDiscoveredCount: 3
        )

        XCTAssertTrue(config.contains("discover_interfaces = yes"),
                      "discovery must be emitted as `discover_interfaces = yes`\n\(config)")
        XCTAssertTrue(config.contains("autoconnect_discovered_interfaces = 3"),
                      "autoconnect count must be emitted verbatim\n\(config)")
    }

    func testDiscoveryConfigKeysEmitDisabledDefaults() {
        let iface = InterfaceEntity(
            name: "kin",
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(targetHost: "rns.kin.earth", targetPort: 4242))
        )
        let config = PythonConfigWriter.write(
            interfaces: [iface],
            discoverInterfaces: false,
            autoconnectDiscoveredCount: 0
        )

        XCTAssertTrue(config.contains("discover_interfaces = no"),
                      "discovery must default to `discover_interfaces = no`\n\(config)")
        XCTAssertTrue(config.contains("autoconnect_discovered_interfaces = 0"),
                      "autoconnect count must default to 0\n\(config)")
    }

    func testTcpClientBootstrapOnlyEmitsBootstrapOnlyKey() {
        let iface = InterfaceEntity(
            name: "kin",
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(
                targetHost: "rns.kin.earth",
                targetPort: 4242,
                bootstrapOnly: true
            ))
        )
        let config = PythonConfigWriter.write(interfaces: [iface])

        XCTAssertTrue(config.contains("bootstrap_only = yes"),
                      "bootstrapOnly must emit `bootstrap_only = yes`\n\(config)")
    }

    func testTcpClientWithoutBootstrapOnlyOmitsBootstrapOnlyKey() {
        let iface = InterfaceEntity(
            name: "kin",
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(targetHost: "rns.kin.earth", targetPort: 4242))
        )
        let config = PythonConfigWriter.write(interfaces: [iface])

        XCTAssertFalse(config.contains("bootstrap_only"),
                       "bootstrap_only must be omitted unless the flag is set\n\(config)")
    }
}

#if COLUMBA_RUNTIME_PYTHON
private final class FakePythonRNodeTransport: PythonRNodeTransporting {
    var onDataReceived: ((Data) -> Void)?
    var onStateChange: ((PythonRNodeLinkState, String?, PythonRNodeFailureCode) -> Void)?
    var connectCount = 0
    var disconnectCount = 0
    var sent: [Data] = []
    var sendHandler: ((Data, @escaping (Error?) -> Void) -> Void)?
    /// When false, connect() does NOT immediately report .connected - it simulates
    /// the async "connecting" window (real CoreBluetooth connects asynchronously).
    var autoConnect = true

    func connect() {
        connectCount += 1
        if autoConnect {
            onStateChange?(.connected, nil, .none)
        }
    }

    func disconnect() {
        disconnectCount += 1
        onStateChange?(.disconnected, nil, .none)
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        sent.append(data)
        if let sendHandler {
            sendHandler(data, completion)
        } else {
            completion(nil)
        }
    }
}

extension PythonConfigWriterTests {
    func testPythonRNodeNativeBridgeConnectsBuffersAndWrites() {
        let fake = FakePythonRNodeTransport()
        let bridge = PythonRNodeBLEBridge(makeTransport: { _, _ in fake })
        var published: [PythonRNodeLinkState] = []
        bridge.setStateHandler { state, _ in published.append(state) }

        XCTAssertTrue(bridge.connect(deviceName: "RNode 1234"))
        XCTAssertEqual(fake.connectCount, 1)
        XCTAssertEqual(bridge.snapshot().0, .connected)
        XCTAssertEqual(published.last, .connecting,
                       "BLE connection must not green the UI before RNode validation")
        bridge.setInterfaceOnline(true)
        XCTAssertEqual(published.last, .connected)

        fake.onDataReceived?(Data([0xC0, 0x08, 0x46, 0xC0]))
        XCTAssertEqual(bridge.read(maxBytes: 2), Data([0xC0, 0x08]))
        XCTAssertEqual(bridge.read(maxBytes: 8), Data([0x46, 0xC0]))

        let outbound = Data([0xC0, 0x01, 0x02, 0xC0])
        XCTAssertEqual(bridge.writeSync(outbound), outbound.count)
        XCTAssertEqual(fake.sent, [outbound])

        bridge.disconnect()
        XCTAssertEqual(fake.disconnectCount, 1)
        XCTAssertEqual(bridge.snapshot().0, .disconnected)
        XCTAssertEqual(bridge.writeSync(outbound), -1)
    }

    func testPythonRNodeNativeBridgeSurfacesFailureReason() {
        let fake = FakePythonRNodeTransport()
        let bridge = PythonRNodeBLEBridge(makeTransport: { _, _ in fake })
        var observed: (PythonRNodeLinkState, String?)?
        bridge.setStateHandler { observed = ($0, $1) }
        XCTAssertTrue(bridge.connect(deviceName: "RNode 1234"))

        fake.onStateChange?(.failed, "pairing lost", .pairingRequired)
        XCTAssertEqual(bridge.snapshot().0, .failed)
        XCTAssertEqual(bridge.snapshot().1, "pairing lost")
        XCTAssertEqual(bridge.failureCode(), .pairingRequired)
        XCTAssertEqual(observed?.0, .failed)
        XCTAssertEqual(observed?.1, "pairing lost")
    }

    func testPythonRNodeBridgeRejectsCompetingDeviceAndIgnoresStaleCallbacks() {
        var transports: [FakePythonRNodeTransport] = []
        let bridge = PythonRNodeBLEBridge(makeTransport: { _, _ in
            let transport = FakePythonRNodeTransport()
            transports.append(transport)
            return transport
        })

        XCTAssertTrue(bridge.connect(deviceName: "RNode A"))
        XCTAssertFalse(bridge.connect(deviceName: "RNode A"))
        XCTAssertFalse(bridge.connect(deviceName: "RNode B"))
        XCTAssertEqual(transports.count, 1)

        let stale = transports[0]
        bridge.disconnect()
        XCTAssertTrue(bridge.connect(deviceName: "RNode B"))
        XCTAssertEqual(transports.count, 2)
        stale.onStateChange?(.failed, "stale failure", .failed)
        XCTAssertEqual(bridge.snapshot().0, .connected)
        XCTAssertNil(bridge.snapshot().1)
    }

    func testStaleWriteTimeoutDoesNotDisconnectReplacementTransport() {
        var transports: [FakePythonRNodeTransport] = []
        let bridge = PythonRNodeBLEBridge(makeTransport: { _, _ in
            let transport = FakePythonRNodeTransport()
            transports.append(transport)
            return transport
        })
        XCTAssertTrue(bridge.connect(deviceName: "RNode A"))
        let stale = transports[0]
        stale.sendHandler = { _, _ in
            bridge.disconnect()
            XCTAssertTrue(bridge.connect(deviceName: "RNode B"))
        }

        XCTAssertEqual(bridge.writeSync(Data([0xC0]), timeout: 0.01), -2)
        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(transports[1].disconnectCount, 0)
        XCTAssertEqual(bridge.snapshot().0, .connected)
    }

    func testPythonRNodeBridgeFailsInsteadOfDroppingOnBufferOverflow() {
        let fake = FakePythonRNodeTransport()
        let bridge = PythonRNodeBLEBridge(makeTransport: { _, _ in fake })
        XCTAssertTrue(bridge.connect(deviceName: "RNode A"))

        fake.onDataReceived?(Data(repeating: 0xAA, count: 1_048_577))
        XCTAssertEqual(bridge.snapshot().0, .failed)
        XCTAssertEqual(bridge.snapshot().1, "RNode inbound buffer overflow")
        XCTAssertEqual(fake.disconnectCount, 1)
        XCTAssertTrue(bridge.read(maxBytes: 1).isEmpty)
    }

    func testPythonRNodeSessionRegistryAllowsDistinctPhysicalDevicesOnly() {
        var transports: [FakePythonRNodeTransport] = []
        let registry = PythonRNodeBLESessionRegistry(makeTransport: { _, _ in
            let transport = FakePythonRNodeTransport()
            transports.append(transport)
            return transport
        })
        let firstID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let secondID = "11111111-2222-3333-4444-555555555555"

        let first = registry.open(deviceName: "RNode", deviceIdentifier: firstID)
        let second = registry.open(deviceName: "RNode", deviceIdentifier: secondID)
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThan(second, 0)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(registry.activeSessionCount, 2)
        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(
            registry.snapshot(
                deviceIdentifier: UUID(uuidString: firstID),
                deviceName: "RNode"
            )?.0,
            .connected
        )
        XCTAssertEqual(
            registry.snapshot(
                deviceIdentifier: UUID(uuidString: secondID),
                deviceName: "RNode"
            )?.0,
            .connected
        )

        XCTAssertEqual(
            registry.open(deviceName: "Renamed RNode", deviceIdentifier: firstID),
            -2,
            "the physical UUID, not the display name, owns the claim"
        )
        XCTAssertTrue(registry.close(handle: first))
        XCTAssertEqual(registry.activeSessionCount, 1)
        XCTAssertGreaterThan(
            registry.open(deviceName: "Renamed RNode", deviceIdentifier: firstID),
            0
        )
        XCTAssertEqual(registry.activeSessionCount, 2)
        XCTAssertEqual(transports[1].disconnectCount, 0,
                       "closing one physical RNode must not disconnect another")
        registry.closeAll()
        XCTAssertEqual(registry.activeSessionCount, 0)
        XCTAssertEqual(transports[1].disconnectCount, 1)
        XCTAssertEqual(transports[2].disconnectCount, 1)

        let legacy = registry.open(deviceName: "Legacy RNode", deviceIdentifier: nil)
        XCTAssertGreaterThan(legacy, 0)
        XCTAssertEqual(
            registry.open(deviceName: "Identified RNode", deviceIdentifier: firstID),
            -1,
            "a name-only legacy claim cannot safely coexist with another RNode"
        )
        XCTAssertTrue(registry.close(handle: legacy))
    }

    // MARK: - Failure persistence lifecycle (Greptile P1)

    /// The persisted pairing_required failure must survive a re-open (the
    /// reconnect after app restart / Apply) while the session is still
    /// connecting, and only clear once the session reports CONNECTED.
    func testPersistentFailureSurvivesReopenAndClearsOnConnect() {
        let id = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        var transports: [FakePythonRNodeTransport] = []
        let registry = PythonRNodeBLESessionRegistry(makeTransport: { _, _ in
            let t = FakePythonRNodeTransport()
            // The first session auto-connects (round 1). The second simulates
            // the async "connecting" window: it does NOT report .connected on
            // open(), so we can observe the persisted failure during that gap.
            t.autoConnect = (transports.count == 0)
            transports.append(t)
            return t
        })

        // Round 1: open, connect, then the transport reports a stale-bond failure
        // (pairingRequired). The session is still open when the failure lands.
        let h1 = registry.open(deviceName: "RNode", deviceIdentifier: id)
        XCTAssertGreaterThan(h1, 0)
        // Simulate the FAILED state arriving (the transport reports it via the
        // 3-param onStateChange; the bridge captures failureCodeValue).
        transports[0].onStateChange?(.failed, "peer removed pairing", .pairingRequired)
        XCTAssertEqual(
            registry.failureCode(deviceIdentifier: UUID(uuidString: id), deviceName: "RNode"),
            .pairingRequired,
            "live session must report the captured failure"
        )
        // Close: the code persists in lastFailureByDevice.
        XCTAssertTrue(registry.close(handle: h1))
        XCTAssertEqual(
            registry.failureCode(deviceIdentifier: UUID(uuidString: id), deviceName: "RNode"),
            .pairingRequired,
            "failure must survive close (session gone, code persisted)"
        )

        // Round 2 (app restart / Apply): re-open. The new session is in the
        // async "connecting" window (autoConnect=false, so it has NOT reported
        // .connected yet and has not failed yet). The persisted failure must
        // STILL be visible - this is the P1 regression: open() used to clear it.
        let h2 = registry.open(deviceName: "RNode", deviceIdentifier: id)
        XCTAssertGreaterThan(h2, 0)
        XCTAssertEqual(
            registry.failureCode(deviceIdentifier: UUID(uuidString: id), deviceName: "RNode"),
            .pairingRequired,
            "failure must remain visible while the replacement session is still connecting"
        )

        // Now the replacement connects successfully. The persisted failure
        // clears lazily (the bond is healthy again).
        transports[1].onStateChange?(.connected, nil, .none)
        XCTAssertEqual(
            registry.failureCode(deviceIdentifier: UUID(uuidString: id), deviceName: "RNode"),
            .none,
            "successful connect must clear the stale persisted failure"
        )
        registry.closeAll()
    }

    /// Greptile P2: the static contract only greps for symbol presence; this
    /// actually runs `classifyRNodeBLEFailure` with representative NSError
    /// values to verify the numeric comparison and branches produce the
    /// correct typed code. A wrong code constant or inverted branch would
    /// disable stale-bond recovery while still passing the static contract.
    func testClassifyStaleBondErrorsProducePairingRequired() {
        // CBErrorDomain 14 = CBErrorPeerRemovedPairingInformation.
        let peerRemoved = NSError(
            domain: CBErrorDomain,
            code: 14,
            userInfo: [NSLocalizedDescriptionKey: "Peer removed pairing information"]
        )
        XCTAssertEqual(
            classifyRNodeBLEFailure(peerRemoved), .pairingRequired,
            "CBErrorDomain 14 (peer removed pairing info) must classify as pairingRequired"
        )

        // CBATTErrorDomain 0x05 = InsufficientAuthentication.
        let insufficientAuth = NSError(domain: CBATTErrorDomain, code: 0x05)
        XCTAssertEqual(
            classifyRNodeBLEFailure(insufficientAuth), .pairingRequired,
            "CBATTErrorDomain 0x05 (insufficient authentication) must classify as pairingRequired"
        )

        // CBATTErrorDomain 0x0F = InsufficientEncryption.
        let insufficientEnc = NSError(domain: CBATTErrorDomain, code: 0x0F)
        XCTAssertEqual(
            classifyRNodeBLEFailure(insufficientEnc), .pairingRequired,
            "CBATTErrorDomain 0x0F (insufficient encryption) must classify as pairingRequired"
        )
    }

    func testClassifyUnrelatedErrorsProduceGenericFailed() {
        // CBErrorDomain 5 = Unknown (not a stale-bond class).
        let cbUnknown = NSError(domain: CBErrorDomain, code: 5)
        XCTAssertEqual(
            classifyRNodeBLEFailure(cbUnknown), .failed,
            "CBErrorDomain 5 (unknown) must classify as generic failed"
        )

        // A generic non-CB error.
        let generic = NSError(domain: "Test", code: 99)
        XCTAssertEqual(
            classifyRNodeBLEFailure(generic), .failed,
            "unrelated error domain must classify as generic failed"
        )
    }
}
#endif
