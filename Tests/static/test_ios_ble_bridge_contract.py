#!/usr/bin/env python3
"""Contracts for shipping iOS↔Android BLEInterface lifecycle and framing."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
APP_ROOT = ROOT / "Sources/ColumbaApp/App/ColumbaApp.swift"
BRIDGE = ROOT / "Sources/SwiftBLEBridge/SwiftBLEBridge.swift"
CLIENT = ROOT / "Sources/SwiftBLEBridge/BleGattClient.swift"
BINDINGS = ROOT / "Sources/SwiftBLEBridge/BleNativeBindings.swift"
DRIVER = ROOT / "app/ble/IOSBLEDriver.py"
INTERFACE = ROOT / "app/ble/IOSBLEInterface.py"
FETCH_WHEELS = ROOT / "support/fetch-wheels.sh"
PROJECT = ROOT / "Columba.xcodeproj/project.pbxproj"
EXPORTS = ROOT / "Sources/ColumbaApp/Resources/ColumbaApp.exports"
RECONCILER = ROOT / "support/isolate-modelb-targets.rb"


class IOSBLEBridgeContracts(unittest.TestCase):
    def test_callback_sink_is_installed_before_python_starts(self) -> None:
        source = APP.read_text()
        install = source.index("PythonBLECallbackBridge(pythonBridge:")
        start = source.index("let info = try await backend.start(")
        self.assertLess(install, start)

    def test_advertising_waits_for_confirmed_service_registration(self) -> None:
        source = BRIDGE.read_text()
        setup = source[source.index("fileprivate func setUpGattServiceIfNeeded"):]
        setup_body = setup.split("// MARK: - Scan + advertise", 1)[0]
        self.assertIn("gattServiceAdding = true\n        pm.add(service)", setup_body)
        self.assertNotIn("gattServiceAdded = true", setup_body)

        advertise = source[source.index("fileprivate func tryStartAdvertiseLocked"):]
        self.assertIn("guard pendingAdvertiseRequested,\n              gattServiceAdded,", advertise)

        did_add = source[source.index("didAdd service: CBService"):]
        did_add = did_add.split("public func peripheralManager(", 1)[0]
        self.assertIn("gattServiceAdded = true", did_add)
        self.assertIn("tryStartAdvertiseLocked()", did_add)

    def test_filtered_discovery_always_reports_configured_service(self) -> None:
        source = BRIDGE.read_text()
        discovery = source[source.index("didDiscover peripheral: CBPeripheral"):]
        discovery = discovery.split("public func centralManager(", 1)[0]
        self.assertIn("let configuredService = serviceCBUUID.uuidString.lowercased()", discovery)
        self.assertIn("serviceUUIDs.append(configuredService)", discovery)

    def test_duplicate_check_precedes_identity_publication(self) -> None:
        source = BRIDGE.read_text()
        central = source[source.index("case identityCharCBUUID:"):]
        central = central.split("case txCharCBUUID:", 1)[0]
        duplicate = central.index("slot: .onDuplicateIdentityDetected")
        publish = central.index("slot: .onIdentityReceived")
        self.assertLess(duplicate, publish)
        self.assertIn("args: [address, identityHex]", central)

        peripheral = source[source.index("if peer.state == .awaitingIdentity"):]
        peripheral = peripheral.split("} else {\n                // Established", 1)[0]
        duplicate = peripheral.index("slot: .onDuplicateIdentityDetected")
        publish = peripheral.index("slot: .onIdentityReceived")
        self.assertLess(duplicate, publish)
        self.assertIn("args: [address, identityHex]", peripheral)

    def test_short_control_values_do_not_enter_fragment_reassembly(self) -> None:
        source = BRIDGE.read_text()
        self.assertGreaterEqual(
            source.count("value.count < BleConstants.fragmentHeaderSize"), 1
        )
        self.assertGreaterEqual(
            source.count("value.count >= BleConstants.fragmentHeaderSize"), 1
        )

    def test_central_handshake_waits_for_subscription_and_identity_ack(self) -> None:
        source = BRIDGE.read_text()
        identity = source[source.index("// Identity characteristic — 16-byte peer identity hash."):]
        identity = identity.split("case txCharCBUUID:", 1)[0]
        self.assertIn("client.state = .subscribing", identity)
        self.assertIn("peripheral.setNotifyValue(true", identity)
        self.assertNotIn("onDeviceConnected", identity)
        self.assertNotIn("type: .withoutResponse", identity)

        notify = source[source.index("didUpdateNotificationStateFor characteristic"):]
        notify = notify.split("public func peripheral(\n        _ peripheral: CBPeripheral,\n        didUpdateValueFor", 1)[0]
        self.assertIn("characteristic.isNotifying", notify)
        self.assertIn("type: .withResponse", notify)

        write = source[source.index("didWriteValueFor characteristic"):]
        write = write.split("public func peripheralIsReady", 1)[0]
        self.assertIn("client.state == .writingIdentity", write)
        self.assertIn("client.notificationsReady", write)
        self.assertIn("slot: .onDeviceConnected", write)

        self.assertIn("case subscribing", CLIENT.read_text())

    def test_dual_links_prefer_usable_mtu_then_identity_and_migrate_python_address(self) -> None:
        source = BRIDGE.read_text()
        resolver = source[source.index("private func resolveDuplicateLocked"):]
        resolver = resolver.split("public func getPeerIdentity", 1)[0]
        self.assertIn("candidateMTU > existingMTU", resolver)
        self.assertIn("candidateMTU == existingMTU", resolver)
        self.assertIn("localIdentity.lexicographicallyPrecedes(candidateIdentity)", resolver)
        self.assertIn("? .central : .peripheral", resolver)
        self.assertNotIn("dedupeDisconnectsToSuppress", source)
        self.assertGreaterEqual(source.count("slot: .onAddressChanged"), 2)
        disconnect = source[source.index("didDisconnectPeripheral peripheral"):]
        disconnect = disconnect.split("// MARK: - CBPeripheralDelegate", 1)[0]
        self.assertIn("slot: .onDeviceDisconnected", disconnect)
        central_migration = source[source.index("candidateRole: .central"):]
        central_migration = central_migration.split("client.peerIdentity = value", 1)[0]
        self.assertIn("slot: .onMtuNegotiated", central_migration)
        self.assertIn("args: [address, client.mtu]", central_migration)

    def test_python_can_query_native_peer_role_mtu_and_rssi(self) -> None:
        bindings = BINDINGS.read_text()
        driver = DRIVER.read_text()
        for symbol in (
            "columba_ble_get_peer_role",
            "columba_ble_get_peer_mtu",
            "columba_ble_get_peer_rssi",
        ):
            self.assertIn(f'@_cdecl("{symbol}")', bindings)
            self.assertIn(f'"{symbol}"', driver)
        self.assertIn("def get_peer_mtu(self, address: str)", driver)
        self.assertIn('return "central"', driver)
        self.assertIn('return "peripheral"', driver)
        # The RSSI query must resolve the Int32.min "unknown" sentinel to
        # None so the detail cards stay hidden when no sample is available.
        self.assertIn("def get_peer_rssi(self, address: str)", driver)
        self.assertIn("def get_last_receive_rssi(self)", driver)
        self.assertIn("return rssi if rssi != _RSSI_UNKNOWN else None", driver)

    def test_peer_rssi_never_falls_back_to_discovery_cache(self) -> None:
        # getPeerRssi must report ONLY a fresh readRSSI() sample from an
        # established central client. Falling back to lastDiscoveryReport
        # (scan-time RSSI) would persist and display a stale value for
        # peripheral-role or disconnected peers, which have no readable
        # RSSI. Regression: Greptile P2 on PR #190 (stale discovery RSSI).
        source = BRIDGE.read_text()
        start = source.index("public func getPeerRssi(address: String)")
        end = source.index("public func getPeerRole(address: String)")
        body = source[start:end]
        # Strip comment lines so the assertion checks the code, not prose.
        code = "\n".join(l.split("//", 1)[0] for l in body.splitlines())
        self.assertIn("client.state == .established", code)
        self.assertIn("client.rssi", code)
        self.assertNotIn("lastDiscoveryReport", code)

    def test_peer_rssi_rejects_stale_poll_samples(self) -> None:
        # If readRSSI() keeps failing, client.rssi stays unversioned and
        # silently ages. getPeerRssi must bound sample age (2 poll
        # intervals) via rssiSampledAt, which didReadRSSI stamps on every
        # accepted sample. Regression: Greptile P2 iteration 2 on PR #190
        # ("Cached RSSI remains stale").
        bridge = BRIDGE.read_text()
        start = bridge.index("public func getPeerRssi(address: String)")
        end = bridge.index("public func getPeerRole(address: String)")
        body = bridge[start:end]
        code = "\n".join(l.split("//", 1)[0] for l in body.splitlines())
        self.assertIn("client.rssiSampledAt", code)
        self.assertIn("2 * rssiPollInterval", code)
        # Every accepted sample must be versioned at write time.
        write = bridge.index("gattClients[address]?.rssi = value")
        self.assertIn(
            "gattClients[address]?.rssiSampledAt = Date()",
            bridge[write:write + 200],
        )
        client = CLIENT.read_text()
        self.assertIn("var rssiSampledAt: Date?", client)

    def test_stalled_central_handshake_times_out_and_releases_peer(self) -> None:
        source = BRIDGE.read_text()
        self.assertIn("private let connectionTimeout: TimeInterval = 30.0", source)
        self.assertIn("armConnectionTimeoutLocked(address: address, client: client)", source)
        timeout = source[source.index("private func armConnectionTimeoutLocked"):]
        timeout = timeout.split("private func cancelConnectionTimeoutLocked", 1)[0]
        self.assertIn("currentClient === armedClient", timeout)
        self.assertIn("connectionAttemptTokens[address] == attemptToken", timeout)
        self.assertIn("currentClient.state != .established", timeout)
        self.assertNotIn("gattClients.removeValue", timeout)
        self.assertIn('emitError("warning", "Connection timeout to', timeout)
        established = source[source.index("client.state = .established"):]
        self.assertIn("cancelConnectionTimeoutLocked(address: address)", established)

        connect = source[source.index("public func connect(address: String)"):]
        connect = connect.split("public func disconnect(address: String)", 1)[0]
        self.assertIn("guard self.gattClients[address] == nil", connect)

    def test_central_callbacks_only_cleanup_the_exact_client_generation(self) -> None:
        source = BRIDGE.read_text()
        callbacks = source[source.index("didConnect peripheral: CBPeripheral"):]
        callbacks = callbacks.split("// MARK: - CBPeripheralDelegate", 1)[0]
        self.assertGreaterEqual(callbacks.count("currentClient.peripheral === peripheral"), 3)
        disconnect = callbacks[callbacks.index("didDisconnectPeripheral peripheral"):]
        self.assertLess(
            disconnect.index("gattClients.removeValue"),
            disconnect.index("slot: .onDeviceDisconnected"),
        )

    def test_restored_native_connections_replay_after_python_callbacks_register(self) -> None:
        source = BRIDGE.read_text()
        driver = DRIVER.read_text()
        bindings = BINDINGS.read_text()
        self.assertIn("public func syncExistingConnections()", source)
        self.assertIn("where client.state == .established", source)
        self.assertIn("where peer.state == .established", source)
        self.assertIn('@_cdecl("columba_ble_sync_existing_connections")', bindings)
        register = driver.index("self._register_callbacks()")
        replay = driver.index("_columba_ble_sync_existing_connections()", register)
        self.assertLess(register, replay)

    def test_ios_native_gatt_server_bypasses_linux_capability_gate(self) -> None:
        source = INTERFACE.read_text()
        super_init = source.index("super().__init__(owner, config)")
        restore = source.index("self.enable_peripheral = bool(enable_peripheral)")
        self.assertLess(super_init, restore)
        self.assertIn("SwiftBLEBridge/CoreBluetooth", source)

    def test_identity_resync_republishes_native_peer_identity(self) -> None:
        bridge = BRIDGE.read_text()
        bindings = BINDINGS.read_text()
        driver = DRIVER.read_text()
        self.assertIn("public func requestIdentityResync(address: String) -> Bool", bridge)
        self.assertIn("gattClients[address]?.peerIdentity", bridge)
        self.assertIn("gattServerPeers[address]?.identity", bridge)
        self.assertIn('@_cdecl("columba_ble_request_identity_resync")', bindings)
        self.assertIn("def request_identity_resync(self, address: str) -> bool", driver)
        self.assertIn("BLE transport identity must be 16 bytes", driver)
        self.assertIn("already_connected = address in self._connected_peers", driver)
        self.assertIn("if already_connected and self.on_device_connected is not None", driver)

    def test_send_rejection_is_synchronous_across_native_abi(self) -> None:
        bridge = BRIDGE.read_text()
        bindings = BINDINGS.read_text()
        driver = DRIVER.read_text()
        send = bridge[bridge.index("public func send(address: String, data: Data) -> Bool"):]
        send = send.split("private func drainClientWritesLocked", 1)[0]
        self.assertIn("queue.sync", send)
        self.assertGreaterEqual(send.count("return false"), 3)
        self.assertIn("? 0 : -1", bindings)
        self.assertIn("raise RuntimeError(f\"columba_ble_send rejected frame", driver)

    def test_debug_urls_cannot_delete_arbitrary_conversations(self) -> None:
        self.assertNotIn("test-delete-conversation", APP_ROOT.read_text())
        self.assertNotIn("ColumbaTestDeleteConversation", APP.read_text())

    def test_application_frames_wait_for_identity_handshake(self) -> None:
        bridge = BRIDGE.read_text()
        send = bridge[bridge.index("public func send(address: String, data: Data) -> Bool"):]
        send = send.split("// MARK: - Queries", 1)[0]
        self.assertGreaterEqual(send.count("if client.state == .established"), 1)
        self.assertGreaterEqual(send.count("if peer.state == .established"), 1)
        central_established = bridge.index("client.state = .established")
        central_drain = bridge.index("drainClientWritesLocked(client)", central_established)
        self.assertLess(central_established, central_drain)
        peripheral_established = bridge.index("peer.state = .established")
        peripheral_drain = bridge.index("drainPeerNotifiesLocked(peer)", peripheral_established)
        self.assertLess(peripheral_established, peripheral_drain)

    def test_all_ctypes_exports_are_linker_retained(self) -> None:
        bindings = BINDINGS.read_text()
        app = APP.read_text()
        self.assertGreaterEqual(bindings.count("@_cdecl(\"columba_ble_"), 10)
        self.assertEqual(
            bindings.count("@_cdecl(\"columba_ble_"),
            bindings.count("@_used\n@_cdecl(\"columba_ble_"),
        )
        self.assertIn("public func columbaBLEForceLinkNativeBindings()", bindings)
        self.assertIn("columbaBLEForceLinkNativeBindings()", app)

    def test_debug_build_keeps_ctypes_exports_in_main_executable(self) -> None:
        project = PROJECT.read_text()
        shipping_debug = project.split("TDBG /* Debug */ = {", 1)[1]
        shipping_debug = shipping_debug.split("name = Debug;", 1)[0]
        self.assertIn("ENABLE_DEBUG_DYLIB = NO;", shipping_debug)

    def test_archive_exports_every_python_native_binding(self) -> None:
        project = PROJECT.read_text()
        shipping_debug = project.split("TDBG /* Debug */ = {", 1)[1]
        shipping_debug = shipping_debug.split("name = Debug;", 1)[0]
        shipping_release = project.split("TREL /* Release */ = {", 1)[1]
        shipping_release = shipping_release.split("name = Release;", 1)[0]
        setting = (
            "EXPORTED_SYMBOLS_FILE = "
            "Sources/ColumbaApp/Resources/ColumbaApp.exports;"
        )
        self.assertNotIn(setting, shipping_debug)
        self.assertIn(setting, shipping_release)
        self.assertIn("STRIP_STYLE = non-global;", shipping_release)

        declared = set()
        for source in (ROOT / "Sources").rglob("*.swift"):
            declared.update(re.findall(r'@_cdecl\("([^\"]+)"\)', source.read_text()))
        exported = {
            line.removeprefix("_")
            for line in EXPORTS.read_text().splitlines()
            if line and not line.startswith("#")
        }
        self.assertEqual(declared, exported)

    def test_reconciler_keeps_native_exports_shipping_only(self) -> None:
        source = RECONCILER.read_text()
        self.assertIn(
            "PYTHON_NATIVE_EXPORTS_FILE = "
            "'Sources/ColumbaApp/Resources/ColumbaApp.exports'",
            source,
        )
        self.assertIn(
            "PYTHON_NATIVE_BUILD_SETTINGS.each { |setting| "
            "configuration.build_settings.delete(setting) }",
            source,
        )
        self.assertIn(
            "configuration.build_settings['EXPORTED_SYMBOLS_FILE'] = "
            "PYTHON_NATIVE_EXPORTS_FILE",
            source,
        )
        self.assertIn("if configuration.name == 'Release'", source)
        self.assertIn("configuration.build_settings['STRIP_STYLE'] = 'non-global'", source)

    def test_central_payload_capacity_refreshes_after_handshake(self) -> None:
        source = BRIDGE.read_text()
        acknowledgement = source[source.index("didWriteValueFor characteristic:"):]
        acknowledgement = acknowledgement.split("public func peripheralIsReady", 1)[0]
        refresh = acknowledgement.index(
            "peripheral.maximumWriteValueLength(for: .withoutResponse)"
        )
        republish = acknowledgement.index("slot: .onMtuNegotiated", refresh)
        established = acknowledgement.index("client.state = .established", refresh)
        self.assertLess(refresh, republish)
        self.assertLess(republish, established)

    def test_ble_ui_labels_characteristic_payload_not_raw_att_mtu(self) -> None:
        view = (ROOT / "Sources/ColumbaApp/Views/Settings/BLEConnectionsView.swift").read_text()
        self.assertIn('label: "Max GATT payload"', view)

    def test_wheel_fetch_uses_modern_packaging_and_requires_ble_runtime(self) -> None:
        script = FETCH_WHEELS.read_text()
        self.assertIn('"pip==25.1.1"', script)
        self.assertIn('"setuptools==80.9.0"', script)
        self.assertIn('$dst/ble_reticulum/BLEInterface.py', script)


if __name__ == "__main__":
    unittest.main()
