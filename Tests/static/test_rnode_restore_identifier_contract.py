#!/usr/bin/env python3
"""Contracts for removal of the legacy RNode picker and unique BLE restore IDs."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Sources"
PROJECT = ROOT / "Columba.xcodeproj/project.pbxproj"
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


if __name__ == "__main__":
    unittest.main()
