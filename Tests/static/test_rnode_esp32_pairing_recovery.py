#!/usr/bin/env python3
"""Regression contracts for ESP32-S3 RNode pairing recovery."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCANNER = ROOT / "Sources/ColumbaApp/Views/Settings/RNodeWizard/RNodeProbeScanner.swift"
DISCOVERY_STEP = ROOT / "Sources/ColumbaApp/Views/Settings/RNodeWizard/DeviceDiscoveryStep.swift"
INTERFACE_VM = ROOT / "Sources/ColumbaApp/ViewModels/InterfaceManagementViewModel.swift"
WIZARD_VM = ROOT / "Sources/ColumbaApp/ViewModels/RNodeWizardViewModel.swift"
WIZARD_VIEW = ROOT / "Sources/ColumbaApp/Views/Settings/RNodeWizard/RNodeWizardView.swift"


class ESP32RNodePairingRecoveryContracts(unittest.TestCase):
    def setUp(self) -> None:
        self.source = SCANNER.read_text()

    def test_pre_detect_disconnect_gets_one_bounded_reconnect(self) -> None:
        self.assertIn("earlyDisconnectRetried", self.source)
        self.assertRegex(
            self.source,
            re.compile(
                r"if\s+!hasSentDetectProbe\s+&&\s+!pairingTriggered\s+&&\s+"
                r"!earlyDisconnectRetried\s*\{.*?needsReconnect\s*=\s*true.*?"
                r"earlyDisconnectRetried\s*=\s*true",
                re.DOTALL,
            ),
        )

    def test_authentication_failed_detect_is_retried_in_place(self) -> None:
        self.assertIn("maxAuthenticationDetectRetries", self.source)
        self.assertRegex(
            self.source,
            re.compile(
                r"Write auth error.*?hasSentDetectProbe\s*=\s*false.*?"
                r"scheduleDetectRetryAfterAuthentication\(\)",
                re.DOTALL,
            ),
        )
        self.assertRegex(
            self.source,
            re.compile(
                r"func scheduleDetectRetryAfterAuthentication\(\).*?"
                r"authenticationDetectRetryCount\s*<\s*Self\.maxAuthenticationDetectRetries.*?"
                r"probeGeneration\s*==\s*generation.*?sendDetectProbe\(\)",
                re.DOTALL,
            ),
        )

    def test_pairing_mode_instructions_are_numbered_before_selection(self) -> None:
        source = DISCOVERY_STEP.read_text()
        self.assertIn('Text("1")', source)
        self.assertIn("Hold the USR button for 5 seconds", source)
        self.assertIn('Text("2")', source)
        self.assertIn("Then select your RNode from the list below", source)

    def test_shipping_allows_distinct_rnodes_and_rejects_same_physical_device(self) -> None:
        source = INTERFACE_VM.read_text()
        self.assertIn("otherEnabledRNodeTargetsSamePhysicalDevice", source)
        self.assertIn("config.deviceIdentifier", source)
        self.assertIn("identifier == existingIdentifier", source)
        self.assertIn("!BackendPreference.modelB", source)
        self.assertIn("That physical RNode is already used", source)

    def test_new_interface_defaults_to_selected_rnode_name(self) -> None:
        wizard = WIZARD_VM.read_text()
        discovery = DISCOVERY_STEP.read_text()
        self.assertRegex(
            wizard,
            re.compile(
                r"func selectDevice\(named name: String, identifier: UUID\).*?"
                r"!isEditing.*?interfaceName == \"RNode\".*?"
                r"interfaceName == selectedDeviceName.*?"
                r"selectedDeviceName = name.*?selectedDeviceIdentifier = identifier.*?interfaceName = name",
                re.DOTALL,
            ),
        )
        self.assertIn(
            "wizard.selectDevice(named: device.name, identifier: device.peripheralId)",
            discovery,
        )

    def test_save_rejection_is_visible_inside_full_screen_wizard(self) -> None:
        source = WIZARD_VIEW.read_text()
        self.assertIn('.alert("Couldn\'t Configure RNode"', source)
        self.assertIn("viewModel.errorMessage != nil", source)
        self.assertIn("Text(viewModel.errorMessage ??", source)

    def test_shipping_status_tracks_every_rnode_session(self) -> None:
        source = INTERFACE_VM.read_text()
        self.assertIn("var pythonRNodeUpdates: [(String, String, InterfaceStatus)]", source)
        self.assertIn("for entity in enabledIfs where entity.type == .rnode", source)
        self.assertIn("PythonRNodeBLESessionRegistry.shared.snapshot", source)
        self.assertIn("for (id, name, status) in pythonRNodeUpdates", source)
        self.assertIn("[RNODE_UI] \\(name) badge -> \\(status.displayName)", source)


if __name__ == "__main__":
    unittest.main()
