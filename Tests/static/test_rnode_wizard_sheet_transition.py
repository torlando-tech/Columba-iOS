#!/usr/bin/env python3
"""Regression contract for selector-to-RNode-wizard modal sequencing."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
VIEW_MODEL = ROOT / "Sources/ColumbaApp/ViewModels/InterfaceManagementViewModel.swift"
SCREEN = ROOT / "Sources/ColumbaApp/Views/Settings/InterfaceManagementScreen.swift"


class RNodeWizardSheetTransitionTests(unittest.TestCase):
    def test_selection_is_deferred_until_type_selector_on_dismiss(self) -> None:
        view_model = VIEW_MODEL.read_text(encoding="utf-8")
        screen = SCREEN.read_text(encoding="utf-8")

        self.assertIn("pendingInterfaceTypeSelection", view_model)
        self.assertIn("func queueInterfaceTypeSelection", view_model)
        self.assertIn("func completePendingInterfaceTypeSelection", view_model)
        self.assertIn(
            "onDismiss: { viewModel.completePendingInterfaceTypeSelection() }",
            screen,
        )
        self.assertIn("viewModel.queueInterfaceTypeSelection(type)", screen)

        option_body = screen.split("private func typeOption", 1)[1].split("} label:", 1)[0]
        self.assertNotIn("selectInterfaceType(type)", option_body)
        self.assertNotIn("dismiss()", option_body)

    def test_rnode_selection_still_routes_to_full_screen_wizard(self) -> None:
        view_model = VIEW_MODEL.read_text(encoding="utf-8")
        settings = (ROOT / "Sources/ColumbaApp/Views/Settings/SettingsView.swift").read_text(encoding="utf-8")

        self.assertIn("if type == .rnode", view_model)
        self.assertIn("showRNodeWizard = true", view_model)
        self.assertIn(".fullScreenCover", settings)
        self.assertIn("RNodeWizardView(viewModel: vm)", settings)


if __name__ == "__main__":
    unittest.main()