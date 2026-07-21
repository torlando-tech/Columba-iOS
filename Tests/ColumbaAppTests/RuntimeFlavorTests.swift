//
//  RuntimeFlavorTests.swift
//  ColumbaAppTests
//
//  Compile-time contract tests for the mutually exclusive shipping-Python and
//  experimental-Model-B app targets.
//

import XCTest
@testable import ColumbaApp

#if COLUMBA_RUNTIME_PYTHON && COLUMBA_RUNTIME_MODEL_B
#error("A test host must select exactly one Columba runtime flavor")
#endif

final class RuntimeFlavorTests: XCTestCase {
    func testActiveFlavorMatchesHostConfiguration() {
        #if COLUMBA_RUNTIME_MODEL_B
        XCTAssertEqual(BackendPreference.runtimeFlavor, .modelB)
        #elseif COLUMBA_RUNTIME_PYTHON
        XCTAssertEqual(BackendPreference.runtimeFlavor, .python)
        #else
        XCTFail("The ColumbaAppTests target must declare its host runtime flavor")
        #endif
    }

    func testExactlyOneCompileTimeFlavorIsActive() {
        #if COLUMBA_RUNTIME_PYTHON
        let pythonFlavorCount = 1
        #else
        let pythonFlavorCount = 0
        #endif

        #if COLUMBA_RUNTIME_MODEL_B
        let modelBFlavorCount = 1
        #else
        let modelBFlavorCount = 0
        #endif

        XCTAssertEqual(
            pythonFlavorCount + modelBFlavorCount,
            1,
            "A test host must select exactly one runtime flavor"
        )
    }

    #if COLUMBA_RUNTIME_PYTHON
    func testPersistedSwiftPreferenceCannotChangeShippingRuntime() {
        let suiteName = "test.RuntimeFlavor.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "useSwiftBackend")

        XCTAssertEqual(BackendPreference.runtimeFlavor(defaults: defaults), .python)
    }

    @MainActor
    func testShippingOnboardingInterfaceSeedingIsIdempotent() throws {
        let suiteName = "test.OnboardingInterfaces.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Prevent the repository's production migration shim from importing standard
        // defaults into this isolated suite.
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
        let privateAuto = InterfaceEntity(
            name: "Private Auto",
            type: .autoInterface,
            enabled: false,
            config: .autoInterface(AutoInterfaceConfig(groupId: "private-group"))
        )
        let scanOnlyBLE = InterfaceEntity(
            name: "Scan-only BLE",
            type: .ble,
            enabled: false,
            config: .ble(BLEConfig(advertise: false, scan: true))
        )
        repository.addInterface(privateAuto)
        repository.addInterface(scanOnlyBLE)
        let viewModel = OnboardingViewModel()
        viewModel.selectedInterfaces = [.auto, .ble, .tcp]
        viewModel.selectedTcpServer = server

        viewModel.seedInterfaces(in: repository)
        viewModel.seedInterfaces(in: repository)

        XCTAssertEqual(repository.interfaces.count, 5)
        XCTAssertEqual(repository.interfaces.filter { $0.type == .autoInterface }.count, 2)
        XCTAssertEqual(repository.interfaces.filter { $0.type == .ble }.count, 2)
        XCTAssertFalse(try XCTUnwrap(repository.interfaces.first { $0.id == privateAuto.id }).enabled)
        XCTAssertFalse(try XCTUnwrap(repository.interfaces.first { $0.id == scanOnlyBLE.id }).enabled)
        let tcpInterfaces = repository.interfaces.filter { $0.type == .tcpClient }
        XCTAssertEqual(tcpInterfaces.count, 1)
        XCTAssertTrue(tcpInterfaces[0].enabled)
    }
    #endif
}
