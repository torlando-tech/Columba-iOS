from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class UIScreenshotterReadinessContractTests(unittest.TestCase):
    def setUp(self):
        self.flows = {
            "contacts-list.yml": "screen_contacts",
            "chats-list.yml": "screen_chats",
            "settings.yml": "screen_settings",
            "map.yml": "map_canvas_ready",
        }

    def test_each_flow_asserts_its_screen_landmark_before_capture(self):
        for filename, identifier in self.flows.items():
            with self.subTest(flow=filename):
                flow = (ROOT / "flows" / filename).read_text()
                assertion = f'id: "{identifier}"'
                self.assertIn("ui-screenshotter: true", flow)
                self.assertIn("- extendedWaitUntil:", flow)
                self.assertIn("- assertVisible:", flow)
                self.assertIn(assertion, flow)
                self.assertLess(flow.index(assertion), flow.index("- takeScreenshot:"))

    def test_map_waits_for_native_tile_readiness_before_asserting_and_capturing(self):
        flow = (ROOT / "flows/map.yml").read_text()
        wait = flow.index("- extendedWaitUntil:")
        ready = flow.index('id: "map_canvas_ready"')
        assertion = flow.index("- assertVisible:", ready)
        capture = flow.index("- takeScreenshot:")
        self.assertLess(wait, ready)
        self.assertLess(ready, assertion)
        self.assertLess(assertion, capture)

        bridge = (ROOT / "Sources/ColumbaApp/Views/Map/MapLibreMapView.swift").read_text()
        self.assertIn("func mapViewDidBecomeIdle(_ mapView: MLNMapView)", bridge)
        self.assertIn('mapView.accessibilityIdentifier = "map_canvas_ready"', bridge)
        self.assertIn('mapView.accessibilityIdentifier = "screen_map"', bridge)

    def test_landmark_identifiers_exist_on_the_corresponding_screens(self):
        expected = {
            "Sources/ColumbaApp/Views/Chats/ChatsView.swift": "screen_chats",
            "Sources/ColumbaApp/Views/Contacts/ContactsView.swift": "screen_contacts",
            "Sources/ColumbaApp/Views/Settings/SettingsView.swift": "screen_settings",
        }
        for relative_path, identifier in expected.items():
            with self.subTest(path=relative_path):
                source = (ROOT / relative_path).read_text()
                self.assertIn(f'.accessibilityIdentifier("{identifier}")', source)

    def test_flows_use_stable_tab_identifiers_instead_of_visible_text(self):
        tabs = {
            "contacts-list.yml": "tab_contacts",
            "settings.yml": "tab_settings",
            "map.yml": "tab_map",
        }
        main_tabs = (ROOT / "Sources/ColumbaApp/Views/MainTabView.swift").read_text()
        for filename, identifier in tabs.items():
            with self.subTest(flow=filename):
                flow = (ROOT / "flows" / filename).read_text()
                self.assertIn(f'id: "{identifier}"', flow)
                self.assertNotIn("optional: true", flow)
                self.assertIn(f'.accessibilityIdentifier("{identifier}")', main_tabs)

    def test_pull_request_ci_installs_runs_and_uploads_screenshotter_output(self):
        workflow = (ROOT / ".github/workflows/tests.yml").read_text()
        self.assertIn("Tests.static.test_ui_screenshotter_readiness", workflow)
        self.assertIn("Install Maestro", workflow)
        self.assertIn("Run screenshot flows", workflow)
        self.assertIn("mobile-dev-inc/Maestro/releases/download/cli-", workflow)
        self.assertIn("xcrun simctl install", workflow)
        self.assertIn('"$GITHUB_WORKSPACE/flows/$flow"', workflow)
        self.assertIn("support/collect-maestro-screenshots.py", workflow)
        self.assertIn("screenshot_status=0", workflow)
        self.assertIn("if ! (", workflow)
        self.assertIn("--allow-missing", workflow)
        self.assertIn('exit "$screenshot_status"', workflow)
        for filename in self.flows:
            self.assertIn(filename, workflow)
        self.assertIn(
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            workflow,
        )
        for action in ("actions/cache", "actions/setup-java", "actions/upload-artifact"):
            self.assertNotIn(f"{action}@v4", workflow)
        self.assertIn("ui-screenshots", workflow)
        self.assertIn("github.event_name == 'pull_request'", workflow)
        self.assertTrue((ROOT / "support/collect-maestro-screenshots.py").is_file())

    def test_debug_launch_hook_bypasses_onboarding_with_a_disposable_identity(self):
        app = (ROOT / "Sources/ColumbaApp/App/ColumbaApp.swift").read_text()
        self.assertIn('arguments.contains("ui-screenshotter")', app)
        self.assertIn("!isScreenshotterLaunch", app)
        self.assertIn("creating disposable screenshotter identity", app)


if __name__ == "__main__":
    unittest.main()
