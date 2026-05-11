import XCTest
@testable import ColumbaApp

@available(iOS 17.0, macOS 14.0, *)
@MainActor
final class TCPClientWizardViewModelTests: XCTestCase {

    // MARK: - Helpers

    private var beleth: TcpCommunityServer {
        TcpCommunityServer.servers.first { $0.host == "rns.beleth.net" && $0.port == 4242 }!
    }

    /// Stub sink that records every save call and the resolved fields.
    final class RecordingSink: TCPClientWizardSaveSink {
        struct Call: Equatable {
            let editingId: String?
            let name: String
            let enabled: Bool
            let mode: InterfaceMode
            let config: TCPClientConfig
        }
        private(set) var calls: [Call] = []
        func saveTCPInterface(
            editing: InterfaceEntity?,
            name: String,
            enabled: Bool,
            mode: InterfaceMode,
            config: TCPClientConfig
        ) {
            calls.append(Call(
                editingId: editing?.id,
                name: name,
                enabled: enabled,
                mode: mode,
                config: config
            ))
        }
    }

    // MARK: - selectServer

    func test_selectServer_prefillsHostPortName_andLeavesCustomModeFalse() {
        let vm = TCPClientWizardViewModel()
        vm.isCustomMode = true // sanity: starts dirty

        vm.selectServer(beleth)

        XCTAssertEqual(vm.targetHost, "rns.beleth.net")
        XCTAssertEqual(vm.targetPort, "4242")
        XCTAssertEqual(vm.interfaceName, "Beleth RNS Hub")
        XCTAssertEqual(vm.isCustomMode, false)
        XCTAssertEqual(vm.selectedServer?.id, beleth.id)
    }

    // MARK: - enableCustomMode

    func test_enableCustomMode_clearsSelection_andBlanksHostPortName() {
        let vm = TCPClientWizardViewModel()
        vm.selectServer(beleth)

        vm.enableCustomMode()

        XCTAssertNil(vm.selectedServer)
        XCTAssertEqual(vm.isCustomMode, true)
        XCTAssertEqual(vm.interfaceName, "")
        XCTAssertEqual(vm.targetHost, "")
        XCTAssertEqual(vm.targetPort, "")
    }

    // MARK: - loadExisting

    func test_loadExisting_matchesCommunityServerByHostPort() {
        let vm = TCPClientWizardViewModel()
        let entity = InterfaceEntity(
            name: "Beleth RNS Hub",
            type: .tcpClient,
            enabled: true,
            mode: .full,
            config: .tcpClient(TCPClientConfig(targetHost: "rns.beleth.net", targetPort: 4242))
        )

        vm.loadExisting(entity)

        XCTAssertEqual(vm.selectedServer?.id, beleth.id)
        XCTAssertEqual(vm.isCustomMode, false)
        XCTAssertEqual(vm.currentStep, .serverSelection)
        XCTAssertEqual(vm.targetHost, "rns.beleth.net")
        XCTAssertEqual(vm.targetPort, "4242")
    }

    func test_loadExisting_unknownHost_entersCustomMode() {
        let vm = TCPClientWizardViewModel()
        let entity = InterfaceEntity(
            name: "Mystery",
            type: .tcpClient,
            enabled: true,
            mode: .full,
            config: .tcpClient(TCPClientConfig(targetHost: "example.invalid", targetPort: 4242))
        )

        vm.loadExisting(entity)

        XCTAssertNil(vm.selectedServer)
        XCTAssertEqual(vm.isCustomMode, true)
        XCTAssertEqual(vm.currentStep, .serverSelection)
    }

    // MARK: - canProceed

    func test_canProceed_step1_requiresSelectionOrCustom() {
        let vm = TCPClientWizardViewModel()
        XCTAssertEqual(vm.canProceed(from: .serverSelection), false)

        vm.isCustomMode = true
        XCTAssertEqual(vm.canProceed(from: .serverSelection), true)

        vm.isCustomMode = false
        vm.selectedServer = beleth
        XCTAssertEqual(vm.canProceed(from: .serverSelection), true)
    }

    func test_canProceed_step2_requiresValidHostAndPort() {
        let vm = TCPClientWizardViewModel()
        vm.interfaceName = "Test"
        vm.targetHost = ""
        vm.targetPort = "4242"
        XCTAssertEqual(vm.canProceed(from: .reviewConfigure), false)

        vm.targetHost = "127.0.0.1"
        vm.targetPort = ""
        XCTAssertEqual(vm.canProceed(from: .reviewConfigure), false)

        vm.targetPort = "abc"
        XCTAssertEqual(vm.canProceed(from: .reviewConfigure), false)

        vm.targetPort = "0"
        XCTAssertEqual(vm.canProceed(from: .reviewConfigure), false)

        vm.targetPort = "70000"
        XCTAssertEqual(vm.canProceed(from: .reviewConfigure), false)

        vm.targetPort = "4242"
        XCTAssertEqual(vm.canProceed(from: .reviewConfigure), true)
    }

    func test_canProceed_step2_requiresNonEmptyName() {
        let vm = TCPClientWizardViewModel()
        vm.targetHost = "127.0.0.1"
        vm.targetPort = "4242"
        vm.interfaceName = ""
        XCTAssertEqual(vm.canProceed(from: .reviewConfigure), false)

        vm.interfaceName = "  "
        XCTAssertEqual(vm.canProceed(from: .reviewConfigure), false)

        vm.interfaceName = "Test"
        XCTAssertEqual(vm.canProceed(from: .reviewConfigure), true)
    }

    // MARK: - save

    func test_save_create_invokesParentSaveWithBuiltConfig() {
        let vm = TCPClientWizardViewModel()
        vm.selectServer(beleth)
        vm.enabled = true
        vm.mode = .full
        vm.networkName = "  test-net  "
        vm.passphrase = "secret"

        let sink = RecordingSink()
        vm.save(into: sink)

        XCTAssertEqual(sink.calls.count, 1)
        let call = sink.calls[0]
        XCTAssertNil(call.editingId)
        XCTAssertEqual(call.name, "Beleth RNS Hub")
        XCTAssertEqual(call.enabled, true)
        XCTAssertEqual(call.mode, .full)
        XCTAssertEqual(call.config.targetHost, "rns.beleth.net")
        XCTAssertEqual(call.config.targetPort, 4242)
        XCTAssertEqual(call.config.networkName, "test-net")
        XCTAssertEqual(call.config.passphrase, "secret")
    }

    func test_save_edit_passesEditingEntity() {
        let vm = TCPClientWizardViewModel()
        let entity = InterfaceEntity(
            name: "Beleth RNS Hub",
            type: .tcpClient,
            enabled: true,
            mode: .full,
            config: .tcpClient(TCPClientConfig(targetHost: "rns.beleth.net", targetPort: 4242))
        )
        vm.loadExisting(entity)

        let sink = RecordingSink()
        vm.save(into: sink)

        XCTAssertEqual(sink.calls.count, 1)
        XCTAssertEqual(sink.calls[0].editingId, entity.id)
    }

    func test_save_emptyAdvancedFields_yieldNilNetworkAndPassphrase() {
        let vm = TCPClientWizardViewModel()
        vm.selectServer(beleth)
        vm.networkName = ""
        vm.passphrase = ""

        let sink = RecordingSink()
        vm.save(into: sink)

        XCTAssertNil(sink.calls[0].config.networkName)
        XCTAssertNil(sink.calls[0].config.passphrase)
    }
}
