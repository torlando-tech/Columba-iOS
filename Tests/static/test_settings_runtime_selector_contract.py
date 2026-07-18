#!/usr/bin/env python3
"""Linux-runnable contract checks for compile-time-only runtime selection."""

from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SETTINGS_VIEW = REPOSITORY_ROOT / "Sources/ColumbaApp/Views/Settings/SettingsView.swift"
SETTINGS_VIEW_MODEL = (
    REPOSITORY_ROOT / "Sources/ColumbaApp/ViewModels/SettingsViewModel.swift"
)
BACKEND_PREFERENCE = (
    REPOSITORY_ROOT / "Sources/ColumbaApp/Services/BackendPreference.swift"
)


class SettingsRuntimeSelectorContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.view_source = SETTINGS_VIEW.read_text(encoding="utf-8")
        cls.view_model_source = SETTINGS_VIEW_MODEL.read_text(encoding="utf-8")
        cls.preference_source = BACKEND_PREFERENCE.read_text(encoding="utf-8")

    def test_settings_view_has_no_runtime_backend_selector_or_relaunch_copy(self) -> None:
        for obsolete_text in (
            'title: "Network Backend"',
            "networkBackendCard",
            "useSwiftBackend",
            "backendChangePending",
            "applyBackendSelection",
            "Relaunch Columba to apply the new backend",
            "Switching takes effect after you relaunch Columba",
        ):
            with self.subTest(obsolete_text=obsolete_text):
                self.assertNotIn(obsolete_text, self.view_source)

    def test_settings_view_model_has_no_runtime_backend_selector_state(self) -> None:
        for obsolete_symbol in (
            "useSwiftBackend",
            "isBackendExpanded",
            "backendChangePending",
            "applyBackendSelection",
            "BackendPreference.isSwift",
        ):
            with self.subTest(obsolete_symbol=obsolete_symbol):
                self.assertNotIn(obsolete_symbol, self.view_model_source)

    def test_backend_preference_exposes_only_compile_time_runtime_capabilities(self) -> None:
        self.assertIn("enum RuntimeFlavor", self.preference_source)
        self.assertIn(
            "static func runtimeFlavor(defaults: UserDefaults) -> RuntimeFlavor",
            self.preference_source,
        )
        self.assertIn("static var modelB: Bool", self.preference_source)
        self.assertNotIn("buildDefaultIsSwift", self.preference_source)
        self.assertNotIn("static var isSwift", self.preference_source)


if __name__ == "__main__":
    unittest.main()
