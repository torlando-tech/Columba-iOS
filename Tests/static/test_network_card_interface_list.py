import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SETTINGS_VM = ROOT / "Sources/ColumbaApp/ViewModels/SettingsViewModel.swift"
SETTINGS_VIEW = ROOT / "Sources/ColumbaApp/Views/Settings/SettingsView.swift"
LOCALIZATIONS = ROOT / "Sources/ColumbaApp/Resources/Localizable.xcstrings"


class NetworkCardInterfaceListContractTests(unittest.TestCase):
    def test_shipping_runtime_passes_every_tcp_state_to_presentation(self):
        source = SETTINGS_VM.read_text()
        refresh = source[source.index("public func refreshConnectionState() async") :]

        self.assertIn("let configuredInterfaces = InterfaceRepository().interfaces", refresh)
        self.assertNotIn("InterfaceRepository().getEnabledInterfaces()", refresh)
        self.assertIn("for (entityId, tcpInterface) in appServices.tcpInterfaces", refresh)
        self.assertIn("runtimeTCPStates[entityId] = await tcpInterface.state", refresh)
        self.assertIn("runtimeStates: runtimeTCPStates", refresh)
        self.assertNotIn("appServices.tcpInterface,", refresh)

    def test_card_renders_plural_multiline_interface_section(self):
        source = SETTINGS_VIEW.read_text()

        self.assertIn('Text("Interfaces:")', source)
        self.assertIn("Text(vm.connectedInterface)", source)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", source)

    def test_new_user_visible_labels_are_localized(self):
        catalog = LOCALIZATIONS.read_text()

        for key in ("Interfaces:", "No active interface", "TCP", "TCP Server"):
            self.assertIn(f'"{key}":', catalog)


if __name__ == "__main__":
    unittest.main()
