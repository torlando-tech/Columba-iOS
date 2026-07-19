#!/usr/bin/env python3
"""Contracts for shipping iOS↔Android BLEInterface lifecycle and framing."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
BRIDGE = ROOT / "Sources/SwiftBLEBridge/SwiftBLEBridge.swift"


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


if __name__ == "__main__":
    unittest.main()
