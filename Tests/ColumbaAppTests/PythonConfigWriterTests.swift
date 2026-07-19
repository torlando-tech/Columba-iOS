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
}

#if COLUMBA_RUNTIME_PYTHON
private final class FakePythonRNodeTransport: PythonRNodeTransporting {
    var onDataReceived: ((Data) -> Void)?
    var onStateChange: ((PythonRNodeLinkState, String?) -> Void)?
    var connectCount = 0
    var disconnectCount = 0
    var sent: [Data] = []

    func connect() {
        connectCount += 1
        onStateChange?(.connected, nil)
    }

    func disconnect() {
        disconnectCount += 1
        onStateChange?(.disconnected, nil)
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        sent.append(data)
        completion(nil)
    }
}

extension PythonConfigWriterTests {
    func testPythonRNodeNativeBridgeConnectsBuffersAndWrites() {
        let fake = FakePythonRNodeTransport()
        let bridge = PythonRNodeBLEBridge(makeTransport: { _ in fake })

        XCTAssertTrue(bridge.connect(deviceName: "RNode 1234"))
        XCTAssertEqual(fake.connectCount, 1)
        XCTAssertEqual(bridge.snapshot().0, .connected)

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
        let bridge = PythonRNodeBLEBridge(makeTransport: { _ in fake })
        var observed: (PythonRNodeLinkState, String?)?
        bridge.setStateHandler { observed = ($0, $1) }
        XCTAssertTrue(bridge.connect(deviceName: "RNode 1234"))

        fake.onStateChange?(.failed, "pairing lost")
        XCTAssertEqual(bridge.snapshot().0, .failed)
        XCTAssertEqual(bridge.snapshot().1, "pairing lost")
        XCTAssertEqual(observed?.0, .failed)
        XCTAssertEqual(observed?.1, "pairing lost")
    }
}
#endif
