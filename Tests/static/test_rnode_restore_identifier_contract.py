#!/usr/bin/env python3
"""Contracts for removal of the legacy RNode picker and unique BLE restore IDs."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Sources"
PROJECT = ROOT / "Columba.xcodeproj/project.pbxproj"
REGISTRY = SOURCES / "RNSAPI/CoreBluetoothRestoreIdentifiers.swift"
SWIFT_BLE_BRIDGE = SOURCES / "SwiftBLEBridge/SwiftBLEBridge.swift"
RNODE_SERVICE = SOURCES / "ColumbaApp/Services/ModelBRNodeService.swift"
LEGACY_FILES = (
    SOURCES / "ColumbaApp/Views/Settings/BLEDevicePickerSheet.swift",
    SOURCES / "ColumbaApp/Views/Settings/RNodeConfigSheet.swift",
)


class RNodeRestoreIdentifierContracts(unittest.TestCase):
    def test_superseded_rnode_picker_is_removed(self) -> None:
        for path in LEGACY_FILES:
            self.assertFalse(path.exists(), f"legacy RNode view still exists: {path}")

        project = PROJECT.read_text()
        self.assertNotIn("BLEDevicePickerSheet.swift", project)
        self.assertNotIn("RNodeConfigSheet.swift", project)

        guarded_sources = [
            path.relative_to(ROOT).as_posix()
            for path in SOURCES.rglob("*.swift")
            if "COLUMBA_BLE_ENABLED" in path.read_text()
        ]
        self.assertEqual([], guarded_sources)

    def test_restore_identifiers_have_one_authoritative_registry(self) -> None:
        registry = REGISTRY.read_text()
        expected = {
            "meshCentral": "network.columba.ble.central",
            "meshPeripheral": "network.columba.ble.peripheral",
            "rnodeCentral": "com.columba.ble.central",
        }
        for name, value in expected.items():
            self.assertRegex(
                registry,
                rf'public static let {name} = "{re.escape(value)}"',
            )
        self.assertIn("Set(all).count == all.count", registry)

        bridge = SWIFT_BLE_BRIDGE.read_text()
        self.assertIn("CoreBluetoothRestoreIdentifiers.meshCentral", bridge)
        self.assertIn("CoreBluetoothRestoreIdentifiers.meshPeripheral", bridge)
        self.assertNotIn('"network.columba.ble.central"', bridge)
        self.assertNotIn('"network.columba.ble.peripheral"', bridge)

        service = RNODE_SERVICE.read_text()
        self.assertIn("import RNSAPI", service)
        self.assertIn("guard Self.restoreIdentifierContractValid else", service)
        self.assertIsNotNone(
            re.search(
                r"restoreIdentifierContractValid.*?CoreBluetoothRestoreIdentifiers\.areUnique.*?"
                r"BLEConstants\.RESTORE_IDENTIFIER_KEY\s*==\s*"
                r"CoreBluetoothRestoreIdentifiers\.rnodeCentral",
                service,
                re.DOTALL,
            )
        )


if __name__ == "__main__":
    unittest.main()
