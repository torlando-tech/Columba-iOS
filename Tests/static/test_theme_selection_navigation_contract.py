import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = ROOT / "Sources/ColumbaApp/App/ColumbaApp.swift"
THEME_MANAGER = ROOT / "Sources/ColumbaApp/Theme/ThemeManager.swift"
UI_FLOW = ROOT / "flows/theme-persistence.yml"


class ThemeSelectionNavigationContractTests(unittest.TestCase):
    """Theme changes must re-render in place via @Observable, never by
    tearing down the root view tree.

    The old design bumped a ``themeVersion`` counter on every theme change and
    applied ``.id(themeVersion)`` to the root view. That forced SwiftUI to
    destroy and recreate the entire tree, which reset ``MainTabView``'s
    ``selectedTab`` @State to ``.chats`` -- so selecting a theme in Settings
    bounced the user to the Chats screen.
    """

    def test_app_root_does_not_force_rebuild_on_theme_change(self) -> None:
        source = APP_ROOT.read_text(encoding="utf-8")

        # No view identity keyed to the theme version anywhere in the app root.
        self.assertNotRegex(
            source,
            r"\.id\(\s*ThemeManager\.shared\.themeVersion\s*\)",
            "App root must not apply .id(themeVersion): it tears down the "
            "whole view tree and resets MainTabView.selectedTab to .chats.",
        )
        # No reference to the counter itself either, so a re-introduction has
        # to be an explicit, reviewed change.
        self.assertNotIn("themeVersion", source)

    def test_theme_manager_does_not_expose_rebuild_counter(self) -> None:
        source = THEME_MANAGER.read_text(encoding="utf-8")

        self.assertNotIn("themeVersion", source)
        # Selection methods still persist state, so behavior is unchanged.
        self.assertIn("func selectPreset(_ preset: PresetThemeId)", source)
        self.assertIn("persistState()", source)

    def test_persisted_theme_state_is_not_externally_writable(self) -> None:
        source = THEME_MANAGER.read_text(encoding="utf-8")

        # The persistence-sensitive properties must be private(set). With the
        # old automatic-persistence observers gone, an internal setter would
        # let a future caller change live theme state without updating
        # `theme_state`, silently losing the change on relaunch. Only the
        # mutation methods (which call persistState()) and restore() may
        # write them, and that requires an explicit, reviewed change here.
        for prop in (
            "colorSchemePreference",
            "activePresetId",
            "activeCustomThemeId",
            "customThemes",
        ):
            self.assertRegex(
                source,
                rf"private\(set\) var {prop}:",
                f"{prop} must be private(set): only ThemeManager mutation "
                "methods and restore() may write persistence-sensitive "
                "theme state.",
            )

    def test_theme_facade_still_delegates_to_observable_manager(self) -> None:
        theme = (
            ROOT / "Sources/ColumbaApp/Theme/Theme.swift"
        ).read_text(encoding="utf-8")

        # Views keep live-updating because the Theme facade reads tracked
        # properties of the @Observable ThemeManager; that is what replaces
        # the forced root rebuild.
        self.assertIn("ThemeManager.shared.accentColor", theme)
        # The root applies the resolved color scheme through the same
        # observable manager, so light/dark switches propagate without a
        # view-tree rebuild.
        app_root = APP_ROOT.read_text(encoding="utf-8")
        self.assertIn("ThemeManager.shared.resolvedColorScheme", app_root)
        manager = THEME_MANAGER.read_text(encoding="utf-8")
        self.assertIn("@Observable", manager)

    def test_flow_asserts_in_place_change_and_persistence(self) -> None:
        flow = UI_FLOW.read_text(encoding="utf-8")

        # After each theme change the flow must assert the user is still on
        # the Settings screen rather than navigating back and reopening.
        self.assertNotIn("Changing the scheme rebuilds the root", flow)
        self.assertNotIn("returns to Chats", flow)
        # The user only navigates to Settings twice: once at the start and
        # once after the relaunch. The old rebuild-and-reopen behavior tapped
        # the Settings tab after every theme change (4 taps total); if that
        # returns, this fails.
        self.assertEqual(
            flow.count('id: "tab_settings|gearshape.fill"'),
            2,
            "Theme changes must be asserted in place, not by re-navigating "
            "to Settings after each change.",
        )
        # In-place assertions: still on Settings immediately after each
        # theme interaction, plus the initial and post-restart navigations.
        self.assertGreaterEqual(flow.count('id: "screen_settings"'), 4)
        # In-place selection assertions on the same screen.
        self.assertIn('id: "appearance_color_scheme_light"', flow)
        self.assertIn('id: "appearance_theme_ocean"', flow)
        self.assertIn("selected: true", flow)
        # Persistence across a real relaunch is still covered.
        self.assertIn("- killApp", flow)


if __name__ == "__main__":
    unittest.main()
