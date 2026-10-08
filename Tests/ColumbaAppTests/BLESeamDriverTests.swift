import XCTest
@testable import ColumbaModelBApp

/// Tests for the Model B BLE seam wire (`BLEDriverSeamMessage`) + the BLE
/// interface gate. The wire is the foundation of the cross-process radio
/// bridge: the NE's Python driver issues `columba_ble_*` commands that the NE
/// forwarder encodes app-bound, and the app's `SwiftBLEBridge` events are
/// decoded NE-bound. These tests prove every case survives an encode/decode
/// round trip (bit-for-bit) so the two processes can't drift apart.
final class BLESeamDriverTests: XCTestCase {

    // MARK: - Wire round-trip

    private func assertRoundTrip(_ message: BLEDriverSeamMessage) {
        let data = message.encode()
        let decoded = try! BLEDriverSeamMessage(decoding: data)
        XCTAssertEqual(decoded, message, "round-trip mismatch for \(message)")
    }

    func testCommandCasesRoundTrip() throws {
        assertRoundTrip(.start(serviceUuid: "37145b00-442d-4a94-917f-8f42c5da28e3",
                               rxCharUuid: "37145b00-442d-4a94-917f-8f42c5da28e5",
                               txCharUuid: "37145b00-442d-4a94-917f-8f42c5da28e4",
                               identityCharUuid: "37145b00-442d-4a94-917f-8f42c5da28e6"))
        assertRoundTrip(.stop)
        assertRoundTrip(.setIdentity(identity: Data([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15])))
        assertRoundTrip(.startScanning)
        assertRoundTrip(.stopScanning)
        assertRoundTrip(.startAdvertising(deviceName: "Columba-TEST", identity: Data(repeating: 7, count: 16)))
        assertRoundTrip(.startAdvertising(deviceName: "", identity: Data()))
        assertRoundTrip(.stopAdvertising)
        assertRoundTrip(.connect(address: "AAAA-BBBB"))
        assertRoundTrip(.disconnect(address: "AAAA-BBBB"))
        assertRoundTrip(.send(address: "AAAA-BBBB", data: Data([0xDE, 0xAD, 0xBE, 0xEF])))
        assertRoundTrip(.send(address: "AAAA-BBBB", data: Data()))
        assertRoundTrip(.syncExistingConnections)
        assertRoundTrip(.requestIdentityResync(address: "AAAA-BBBB"))
        assertRoundTrip(.configurePower(address: "", txPowerDbm: 0))
    }

    func testEventCasesRoundTrip() throws {
        assertRoundTrip(.deviceDiscovered(address: "peer-A", name: "AndroidPhone", rssi: -60))
        assertRoundTrip(.deviceDiscovered(address: "peer-A", name: "", rssi: Int16.min))
        assertRoundTrip(.deviceConnected(address: "peer-A", peerIdentity: Data(repeating: 1, count: 16)))
        assertRoundTrip(.deviceConnected(address: "peer-A", peerIdentity: nil))
        assertRoundTrip(.deviceDisconnected(address: "peer-A"))
        assertRoundTrip(.dataReceived(address: "peer-A", data: Data([9, 8, 7])))
        assertRoundTrip(.dataReceived(address: "peer-A", data: Data()))
        assertRoundTrip(.mtuNegotiated(address: "peer-A", mtu: 185))
        assertRoundTrip(.mtuNegotiated(address: "peer-A", mtu: 0))
        assertRoundTrip(.identityReceived(address: "peer-A", identityHex: "00112233445566778899aabbccddeeff"))
        assertRoundTrip(.identityReceived(address: "peer-A", identityHex: ""))
        assertRoundTrip(.addressChanged(old: "old-addr", new: "new-addr", identityHash: "00112233445566778899aabbccddeeff"))
        assertRoundTrip(.error(severity: "error", message: "Bluetooth power off"))
        assertRoundTrip(.error(severity: "info", message: ""))
    }

    /// Distinct messages must not collide to the same encoding (tag confusion
    /// would silently mis-deliver commands across the process boundary).
    func testDistinctMessagesHaveDistinctEncodings() {
        let samples: [BLEDriverSeamMessage] = [
            .stop, .stopScanning, .stopAdvertising, .syncExistingConnections,
            .startScanning, .deviceDisconnected(address: "a"), .connect(address: "a"),
        ]
        let encodings = Set(samples.map { $0.encode() })
        XCTAssertEqual(encodings.count, samples.count, "two distinct messages encoded identically")
    }

    // MARK: - BLE interface gate

    func testModelBBLEServiceGatedOnEnabledBLEInterface() {
        let suiteName = "test.ModelBBLEInterfaceGate.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let repo = InterfaceRepository(userDefaults: defaults)
        func gate() -> Bool {
            // shouldStart and hasEnabledBLEInterface must agree on the same repo.
            let should = ModelBBLEService.shouldStart(repo: repo)
            let has = ModelBBLEService.hasEnabledBLEInterface(repo: repo)
            precondition(should == has, "shouldStart and hasEnabledBLEInterface disagree")
            return should
        }

        // No interfaces → not started.
        XCTAssertFalse(gate())

        // A non-BLE interface alone must not start the BLE host.
        let server = TcpCommunityServer.defaultServer
        repo.addInterface(InterfaceEntity(
            name: server.name,
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(
                targetHost: server.host,
                targetPort: server.port
            ))
        ))
        XCTAssertFalse(gate())

        // An enabled .ble interface starts the host.
        let bleId = "test-ble-\(UUID().uuidString)"
        repo.addInterface(InterfaceEntity(
            id: bleId,
            name: "Bluetooth LE",
            type: .ble,
            config: .ble(BLEConfig())
        ))
        XCTAssertTrue(gate())

        // Disabling that .ble interface stops the gate (presence alone is not enough).
        repo.toggleInterface(id: bleId, enabled: false)
        XCTAssertFalse(gate())

        // Re-enabling brings it back.
        repo.toggleInterface(id: bleId, enabled: true)
        XCTAssertTrue(gate())
    }

    @MainActor
    func testModelBSeedingReenablesDisabledRelayWithoutDuplicate() throws {
        let suiteName = "test.ModelBOnboardingInterfaces.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(try JSONEncoder().encode([InterfaceEntity]()), forKey: "com.columba.interfaces")
        let repository = InterfaceRepository(userDefaults: defaults)
        let server = TcpCommunityServer.defaultServer
        repository.addInterface(InterfaceEntity(
            name: server.name,
            type: .tcpClient,
            enabled: false,
            config: .tcpClient(TCPClientConfig(
                targetHost: server.host,
                targetPort: server.port
            ))
        ))
        let viewModel = OnboardingViewModel()
        viewModel.selectedTcpServer = server

        viewModel.seedInterfaces(in: repository)
        viewModel.seedInterfaces(in: repository)

        XCTAssertEqual(repository.interfaces.count, 1)
        XCTAssertTrue(repository.interfaces[0].enabled)
    }

    @MainActor
    func testModelBSeedingKeepsDifferentIFACRelayDisabled() throws {
        let suiteName = "test.ModelBOnboardingIFAC.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(try JSONEncoder().encode([InterfaceEntity]()), forKey: "com.columba.interfaces")
        let repository = InterfaceRepository(userDefaults: defaults)
        let server = TcpCommunityServer.defaultServer
        let privateRelay = InterfaceEntity(
            name: "Private IFAC relay",
            type: .tcpClient,
            enabled: false,
            config: .tcpClient(TCPClientConfig(
                targetHost: server.host,
                targetPort: server.port,
                networkName: "private-network",
                passphrase: "private-passphrase"
            ))
        )
        repository.addInterface(privateRelay)
        let gatewayRelay = InterfaceEntity(
            name: "Gateway-mode public relay",
            type: .tcpClient,
            enabled: false,
            mode: .gateway,
            config: .tcpClient(TCPClientConfig(
                targetHost: server.host,
                targetPort: server.port
            ))
        )
        repository.addInterface(gatewayRelay)
        let viewModel = OnboardingViewModel()
        viewModel.selectedTcpServer = server

        viewModel.seedInterfaces(in: repository)
        viewModel.seedInterfaces(in: repository)

        XCTAssertEqual(repository.interfaces.count, 3)
        XCTAssertEqual(repository.interfaces.filter(\.enabled).count, 1)
        XCTAssertFalse(try XCTUnwrap(repository.interfaces.first { $0.id == privateRelay.id }).enabled)
        XCTAssertFalse(try XCTUnwrap(repository.interfaces.first { $0.id == gatewayRelay.id }).enabled)
    }
}
