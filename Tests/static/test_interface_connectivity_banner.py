import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MAIN_TAB = ROOT / "Sources/ColumbaApp/Views/MainTabView.swift"
SETTINGS = ROOT / "Sources/ColumbaApp/Views/Settings/SettingsView.swift"
LOCALIZATIONS = ROOT / "Sources/ColumbaApp/Resources/Localizable.xcstrings"
UI_FLOW = ROOT / "flows/interface-connectivity-banner.yml"
CI_WORKFLOW = ROOT / ".github/workflows/tests.yml"


class InterfaceConnectivityBannerContractTests(unittest.TestCase):
    def test_shipping_banner_uses_live_aggregate_connection_state(self) -> None:
        source = MAIN_TAB.read_text(encoding="utf-8")

        self.assertIn("#if COLUMBA_RUNTIME_PYTHON", source)
        self.assertIn("isConnected: appServices.isConnected", source)
        self.assertIn('accessibilityIdentifier("interface_connectivity_banner")', source)
        self.assertIn(
            'accessibilityIdentifier("connectivity_banner_manage_interfaces")',
            source,
        )

    def test_banner_action_routes_directly_to_interface_management(self) -> None:
        main_tab = MAIN_TAB.read_text(encoding="utf-8")
        settings = SETTINGS.read_text(encoding="utf-8")

        self.assertIn("selectedTab = .settings", main_tab)
        self.assertIn("shouldOpenInterfaceManagement = true", main_tab)
        self.assertIn(
            "shouldOpenInterfaceManagement: $shouldOpenInterfaceManagement",
            main_tab,
        )
        self.assertIn(".onChange(of: shouldOpenInterfaceManagement)", settings)
        self.assertIn("openRequestedInterfaceManagement()", settings)
        self.assertIn("showInterfaceManagement = true", settings)
        self.assertIn("shouldOpenInterfaceManagement = false", settings)

    def test_persistent_banner_uses_compact_single_row(self) -> None:
        source = MAIN_TAB.read_text(encoding="utf-8")

        self.assertIn("HStack(spacing: 10)", source)
        self.assertIn(".frame(minHeight: 32)", source)
        self.assertIn('String(localized: "Manage")', source)
        self.assertNotIn("Text(content.message)", source)
        self.assertNotIn("Add or configure a network interface", source)

    def test_banner_copy_is_translation_ready(self) -> None:
        catalog = json.loads(LOCALIZATIONS.read_text(encoding="utf-8"))
        required = {
            "No Interfaces Connected",
            "Manage",
            "Manage Interfaces",
            "Opens network interface settings",
        }

        self.assertTrue(required.issubset(catalog["strings"]))

    def test_ui_flow_covers_cold_mounted_and_repeated_routes(self) -> None:
        flow = UI_FLOW.read_text(encoding="utf-8")
        workflow = CI_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("interface-connectivity-banner.yml", workflow)
        self.assertIn('id: "interface_connectivity_banner"', flow)
        self.assertEqual(
            flow.count('id: "connectivity_banner_manage_interfaces"'),
            3,
        )
        self.assertGreaterEqual(flow.count('text: "Network Interfaces"'), 3)
        self.assertIn('id: "screen_settings"', flow)
        self.assertGreaterEqual(flow.count('id: "tab_chats|message.fill"'), 3)


if __name__ == "__main__":
    unittest.main()
