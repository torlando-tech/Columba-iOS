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

    def test_model_b_card_reads_rnode_from_ne_not_app_stub(self):
        # Model B runs the RNode radio in the Network Extension, so the card must
        # surface RNode state from the NE-authoritative accessor (the same source
        # the Manage Interfaces screen uses), not the app-side Compat stub which
        # never holds the live GATT link. Reading the stub made a connected RNode
        # (verified by cross-device announce) report "disconnected" with no RNode
        # listed on the card. The NE read must come FIRST so the Model B branch is
        # never demoted to the `else if` stub fallback below it.
        source = SETTINGS_VM.read_text()
        refresh = source[source.index("public func refreshConnectionState() async") :]

        self.assertIn("await appServices.neRNodeStatus()", refresh)
        self.assertIn("appServices.rnodeInterface", refresh)  # Model A fallback
        ne_read = refresh.index("await appServices.neRNodeStatus()")
        stub_read = refresh.index("appServices.rnodeInterface")
        self.assertLess(
            ne_read, stub_read,
            "Model B must read RNode from the NE before the app-side stub fallback",
        )


if __name__ == "__main__":
    unittest.main()
