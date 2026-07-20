from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
ONBOARDING_VIEW = ROOT / "Sources/ColumbaApp/Views/Onboarding/OnboardingView.swift"
CONNECTIVITY_PAGE = ROOT / "Sources/ColumbaApp/Views/Onboarding/ConnectivityPage.swift"
PERMISSIONS_PAGE = ROOT / "Sources/ColumbaApp/Views/Onboarding/PermissionsPage.swift"
VIEW_MODEL = ROOT / "Sources/ColumbaApp/ViewModels/OnboardingViewModel.swift"
APP_ENTRY = ROOT / "Sources/ColumbaApp/App/ColumbaApp.swift"


def source(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class OnboardingInterfaceSelectionContracts(unittest.TestCase):
    def test_connectivity_page_is_flavor_specific(self) -> None:
        text = source(CONNECTIVITY_PAGE)
        self.assertIn("@Binding var selectedInterfaces: Set<OnboardingInterfaceType>", text)
        conditional = re.search(
            r"(?ms)#if COLUMBA_RUNTIME_MODEL_B\s+(?P<model_b>.*?)"
            r"#else\s+(?P<shipping>.*?)#endif",
            text,
        )
        self.assertIsNotNone(conditional, "connectivity UI must branch by runtime flavor")
        assert conditional is not None
        model_b = conditional.group("model_b")
        shipping = conditional.group("shipping")
        self.assertIn('Text("Choose a relay")', model_b)
        self.assertNotIn("OnboardingInterfaceType.allCases", model_b)
        self.assertIn('Text("How will you connect?")', shipping)
        self.assertIn("OnboardingInterfaceType.allCases", shipping)
        self.assertIn("interfaceCard(type)", shipping)
        self.assertIn("if selectedInterfaces.contains(.tcp)", shipping)
        self.assertIn("selectedInterfaces.insert(type)", text)
        self.assertIn("selectedInterfaces.remove(type)", text)
        self.assertIn("if type == .ble", text)
        self.assertNotIn("if type == .rnode", text)

    def test_shipping_selection_is_bound_into_the_flow(self) -> None:
        text = source(ONBOARDING_VIEW)
        self.assertIn("selectedInterfaces: $viewModel.selectedInterfaces", text)
        self.assertNotIn("if viewModel.bluetoothAuthorization == .notDetermined", text)

    def test_shipping_interfaces_are_persisted_but_model_b_only_seeds_relay(self) -> None:
        text = source(VIEW_MODEL)
        self.assertIn("var selectedInterfaces: Set<OnboardingInterfaceType> = [.tcp]", text)
        method = text.split("private func createInterfaces(in repo: InterfaceRepository) {", 1)[1]
        conditional = re.search(
            r"(?ms)#if COLUMBA_RUNTIME_MODEL_B\s+(?P<model_b>.*?)"
            r"#else\s+(?P<shipping>.*?)#endif",
            method,
        )
        self.assertIsNotNone(conditional, "interface persistence must branch by runtime flavor")
        assert conditional is not None
        model_b = conditional.group("model_b")
        shipping = conditional.group("shipping")
        self.assertIn("selectedTcpServer ?? TcpCommunityServer.defaultServer", model_b)
        self.assertNotIn("for interfaceType in selectedInterfaces", model_b)
        self.assertIn("for interfaceType in selectedInterfaces", shipping)
        for case in (".auto", ".nearby", ".ble", ".tcp", ".rnode"):
            self.assertIn(f"case {case}:", shipping)

    def test_bluetooth_permission_is_explicit_and_model_b_card_is_not_shipping_ui(self) -> None:
        permissions = source(PERMISSIONS_PAGE)
        self.assertRegex(
            permissions,
            r"(?s)#if COLUMBA_RUNTIME_MODEL_B\s+"
            r"// Bluetooth permission card.*?Text\(\"Bluetooth\"\).*?#endif",
        )

        app = source(APP_ENTRY)
        restore = "SwiftBLEBridge.shared.restoreAtLaunch()"
        self.assertEqual(1, app.count(restore))
        restore_offset = app.index(restore)
        guard_offset = app.rfind("if ", 0, restore_offset)
        guard = app[guard_offset:restore_offset]
        self.assertIn("getEnabledInterfaces()", guard)
        self.assertIn(".ble", guard)


if __name__ == "__main__":
    unittest.main()
