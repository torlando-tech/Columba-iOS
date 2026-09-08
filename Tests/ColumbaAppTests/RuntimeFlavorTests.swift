//
//  RuntimeFlavorTests.swift
//  ColumbaAppTests
//
//  Compile-time contract tests for the mutually exclusive shipping-Python and
//  experimental-Model-B app targets.
//

import XCTest
import RNSAPI
@testable import ColumbaApp

#if COLUMBA_RUNTIME_PYTHON && COLUMBA_RUNTIME_MODEL_B
#error("A test host must select exactly one Columba runtime flavor")
#endif

final class RuntimeFlavorTests: XCTestCase {
    func testNetworkCardListsEveryConnectedTCPInterface() {
        let interfaces = [
            InterfaceEntity(
                id: "primary",
                name: "Primary Relay",
                type: .tcpClient,
                config: .tcpClient(TCPClientConfig(targetHost: "relay-one.example", targetPort: 4242))
            ),
            InterfaceEntity(
                id: "secondary",
                name: "Secondary Relay",
                type: .tcpClient,
                config: .tcpClient(TCPClientConfig(targetHost: "relay-two.example", targetPort: 4243))
            ),
            InterfaceEntity(
                id: "offline",
                name: "Offline Relay",
                type: .tcpClient,
                config: .tcpClient(TCPClientConfig(targetHost: "offline.example", targetPort: 4244))
            ),
        ]

        let descriptions = NetworkInterfacePresentation.tcpDescriptions(
            configuredInterfaces: interfaces,
            runtimeStates: [
                "primary": .connected,
                "secondary": .connected,
                "offline": .disconnected,
            ]
        )

        XCTAssertEqual(
            descriptions,
            [
                "TCP (relay-one.example:4242)",
                "TCP (relay-two.example:4243)",
            ]
        )
        XCTAssertEqual(
            NetworkInterfacePresentation.listText(descriptions),
            "TCP (relay-one.example:4242)\nTCP (relay-two.example:4243)"
        )
    }

    func testNetworkCardAccountsForServerUnknownAndDisabledTCPStates() {
        let interfaces = [
            InterfaceEntity(
                id: "server",
                name: "Local Server",
                type: .tcpServer,
                config: .tcpServer(TCPServerConfig(listenIp: "0.0.0.0", listenPort: 4242))
            ),
            InterfaceEntity(
                id: "disabled",
                name: "Disabled Relay",
                type: .tcpClient,
                enabled: false,
                config: .tcpClient(TCPClientConfig(targetHost: "disabled.example", targetPort: 4243))
            ),
        ]

        XCTAssertEqual(
            NetworkInterfacePresentation.tcpDescriptions(
                configuredInterfaces: interfaces,
                runtimeStates: [
                    "server": .connected,
                    "disabled": .connected,
                    "legacy-one": .connected,
                    "legacy-two": .connected,
                    "legacy-offline": .disconnected,
                ]
            ),
            [
                "TCP Server (0.0.0.0:4242)",
                "TCP",
                "TCP",
            ]
        )
    }

    func testDisconnectedInterfaceBannerOffersDirectRecovery() {
        XCTAssertEqual(
            InterfaceConnectivityBannerContent.forConnectionState(isConnected: false),
            InterfaceConnectivityBannerContent(
                title: "No Interfaces Connected",
                actionTitle: "Manage"
            )
        )
    }

    // MARK: - Network card: auxiliary (discovery-spawned) interfaces

    private func auxSnapshot(
        id: String,
        name: String,
        online: Bool,
        isAutoconnect: Bool = false,
        isAutoInterfacePeer: Bool = false,
        isBLEPeerInterface: Bool = false
    ) -> InterfaceSnapshot {
        InterfaceSnapshot(
            id: id,
            name: name,
            online: online,
            typeLabel: isAutoInterfacePeer ? "AutoInterfacePeer" : "TCPClient",
            type: .tcp,
            state: online ? .connected : .disconnected,
            isAutoInterfacePeer: isAutoInterfacePeer,
            isBLEPeerInterface: isBLEPeerInterface,
            isAutoconnect: isAutoconnect
        )
    }

    func testNetworkCardListsDiscoveryAutoConnectsFlaggedDiscovered() {
        let aux = [
            auxSnapshot(id: "py-aux:1", name: "Hub Node", online: true, isAutoconnect: true),
            auxSnapshot(id: "py-aux:2", name: "Other Node", online: true, isAutoconnect: true),
            auxSnapshot(id: "py-aux:3", name: "Offline Node", online: false, isAutoconnect: true),
        ]
        XCTAssertEqual(
            NetworkInterfacePresentation.auxiliaryDescriptions(aux),
            [
                "Hub Node (Discovered)",
                "Other Node (Discovered)",
            ]
        )
    }

    func testNetworkCardRollsUpLanPeersAndIgnoresBle() {
        let aux = [
            auxSnapshot(id: "py-aux:a", name: "AutoInterfacePeer[en0/fe80::1]", online: true, isAutoInterfacePeer: true),
            auxSnapshot(id: "py-aux:b", name: "AutoInterfacePeer[en0/fe80::2]", online: true, isAutoInterfacePeer: true),
            auxSnapshot(id: "py-aux:c", name: "BLEPeerInterface[AA:BB]", online: true, isBLEPeerInterface: true),
        ]
        XCTAssertEqual(
            NetworkInterfacePresentation.auxiliaryDescriptions(aux),
            ["AutoInterface (2 peers)"]
        )
    }

    func testNetworkCardAuxiliarySingleLanPeerSingular() {
        let aux = [
            auxSnapshot(id: "py-aux:a", name: "AutoInterfacePeer[en0/fe80::1]", online: true, isAutoInterfacePeer: true),
        ]
        XCTAssertEqual(
            NetworkInterfacePresentation.auxiliaryDescriptions(aux),
            ["AutoInterface (1 peer)"]
        )
    }

    func testConnectedInterfaceHidesConnectivityBanner() {
        XCTAssertNil(
            InterfaceConnectivityBannerContent.forConnectionState(isConnected: true)
        )
    }

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

    @MainActor
    func testShippingSkipAlwaysSeedsCanonicalDefaultRelay() throws {
        let suiteName = "test.OnboardingSkipDefault.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(try JSONEncoder().encode([InterfaceEntity]()), forKey: "com.columba.interfaces")
        let repository = InterfaceRepository(userDefaults: defaults)
        let viewModel = OnboardingViewModel()
        viewModel.selectedInterfaces = []
        viewModel.selectedTcpServer = TcpCommunityServer(
            name: "Custom relay",
            host: "custom.invalid",
            port: 4242,
            isBootstrap: false
        )

        viewModel.seedDefaultTcpInterface(in: repository)
        viewModel.seedDefaultTcpInterface(in: repository)

        let interfaces = repository.interfaces
        XCTAssertEqual(interfaces.count, 1)
        guard case let .tcpClient(config) = interfaces[0].config else {
            return XCTFail("Skip must seed a TCP client")
        }
        XCTAssertTrue(interfaces[0].enabled)
        XCTAssertEqual(config.targetHost, TcpCommunityServer.defaultServer.host)
        XCTAssertEqual(config.targetPort, TcpCommunityServer.defaultServer.port)
    }

    @MainActor
    func testSettingsReviewReusesActiveIdentityAndCurrentCustomRelay() throws {
        let suiteName = "test.OnboardingReview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(try JSONEncoder().encode([InterfaceEntity]()), forKey: "com.columba.interfaces")
        let repository = InterfaceRepository(userDefaults: defaults)
        repository.addInterface(InterfaceEntity(
            name: "Private relay",
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(targetHost: "relay.example", targetPort: 4242))
        ))
        let existing = LocalIdentity(
            identityHash: "identity-hash",
            displayName: "Existing Peer",
            destinationHash: "destination-hash",
            createdAt: 1,
            lastUsedAt: 2,
            isActive: true
        )

        let viewModel = OnboardingViewModel(
            existingIdentity: existing,
            interfaceRepository: repository
        )

        XCTAssertTrue(viewModel.isReviewingExistingSetup)
        XCTAssertEqual(viewModel.createdIdentity?.identityHash, existing.identityHash)
        XCTAssertEqual(viewModel.displayName, existing.displayName)
        XCTAssertEqual(viewModel.selectedInterfaces, [.tcp])
        XCTAssertEqual(viewModel.selectedTcpServer?.host, "relay.example")
        XCTAssertEqual(viewModel.selectedTcpServer?.name, "Private relay")
    }

    /// Issue #193 / Greptile P1 #1: the discovery card's "Connected" badge
    /// compares the bridge's `autoconnected` endpoint list against each
    /// interface's `reachable_on:port`. `discovery_json()` emits the
    /// canonical endpoint (IPv6 bracketed, exactly as
    /// `BackboneInterface.__str__` renders it), so the Swift side must build
    /// the SAME canonical string. Pinning it keeps the two sides in sync and
    /// stops the badge from silently never matching (the old code compared a
    /// bare `host:port` against a friendly "BackboneInterface[...]" string).
    func testCanonicalEndpointMatchingBadge() {
        // IPv4 — bare host:port, unchanged.
        XCTAssertEqual(
            DiscoveredInterfacesViewModel.canonicalEndpoint(host: "1.2.3.4", port: 4242),
            "1.2.3.4:4242"
        )
        // IPv6 — bracketed, matching the bridge's f"[{ip}]:{port}" render.
        XCTAssertEqual(
            DiscoveredInterfacesViewModel.canonicalEndpoint(host: "2001:db8::1", port: 8080),
            "[2001:db8::1]:8080"
        )
        // A hostname stays bare (only ":" is the IPv6 trigger).
        XCTAssertEqual(
            DiscoveredInterfacesViewModel.canonicalEndpoint(host: "hub.example", port: 4242),
            "hub.example:4242"
        )
    }

    /// Issue #193 / Greptile P1 #2: a SAME-PROCESS Reticulum re-init is unsafe
    /// when an AutoInterface is configured (its `detach()` only flips
    /// `online = False` — the multicast sockets are local vars never closed,
    /// so re-init hits the documented multicast-bind collision and the re-init
    /// error path takes the backend down). `restartPythonBackend` must refuse
    /// (`.requiresRelaunch`) exactly in that case and proceed for any other
    /// interface set. Pure predicate, so it's testable without a backend.
    func testInProcessRestartBlockedOnlyByAutoInterface() {
        func autoInterfaceEntity() -> InterfaceEntity {
            InterfaceEntity(
                name: "Auto",
                type: .autoInterface,
                enabled: true,
                config: .autoInterface(AutoInterfaceConfig())
            )
        }
        func tcpClientEntity() -> InterfaceEntity {
            InterfaceEntity(
                name: "Relay",
                type: .tcpClient,
                enabled: true,
                config: .tcpClient(TCPClientConfig(targetHost: "h", targetPort: 4242))
            )
        }
        func rnodeEntity() -> InterfaceEntity {
            InterfaceEntity(
                name: "RNode",
                type: .rnode,
                enabled: true,
                config: .rnode(RNodeConfig())
            )
        }
        // Empty and non-AutoInterface sets: in-process restart is safe.
        XCTAssertFalse(AppServices.inProcessRestartBlockedByAutoInterface([]))
        XCTAssertFalse(AppServices.inProcessRestartBlockedByAutoInterface([tcpClientEntity(), rnodeEntity()]))
        // An AutoInterface (even alongside others) blocks it.
        XCTAssertTrue(AppServices.inProcessRestartBlockedByAutoInterface([autoInterfaceEntity()]))
        XCTAssertTrue(AppServices.inProcessRestartBlockedByAutoInterface([tcpClientEntity(), autoInterfaceEntity()]))
    }
    #endif
}
