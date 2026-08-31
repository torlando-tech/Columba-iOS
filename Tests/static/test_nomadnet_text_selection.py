#!/usr/bin/env python3
"""Behavioral contract: NomadNet browser text must be selectable and copyable
(Android parity, issue #188).

Android's ``MicronPageContent`` wraps the whole micron page in a Compose
``SelectionContainer`` so a long-press anywhere selects and copies text. iOS
renders its three modes differently, so the fix splits across files:

  * ``MicronDocumentView.swift`` (the wrapping modes render real SwiftUI
    ``Text``) enables native long-press select/copy with ``.textSelection`` -
    but ONLY in the non-scroll modes, because ``.monospaceScroll`` renders
    UIKit ``UILabel``s which that modifier cannot reach.
  * ``MonospaceLineView.swift`` (the default ``.monospaceScroll`` mode) adds a
    native long-press ``UIContextMenuInteraction`` to each line's ``UILabel``
    with a single "Copy" action.
  * ``NomadNetBrowserView.swift`` adds a "Copy Page" toolbar action that copies
    the loaded page's readable plain text (``MicronDocument.plainText``) in
    every mode - the whole-page fallback.

This contract pins all four halves so the feature cannot silently regress.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MICRON_DOC = ROOT / "Sources/ColumbaApp/Views/NomadNet/MicronDocumentView.swift"
MICRON_LINE = ROOT / "Sources/ColumbaApp/Views/NomadNet/MonospaceLineView.swift"
BROWSER_VIEW = ROOT / "Sources/ColumbaApp/Views/NomadNet/NomadNetBrowserView.swift"
MICRON_MODEL = ROOT / "Sources/ColumbaApp/Models/MicronDocument.swift"


def _read(path: Path) -> str:
    assert path.is_file(), f"missing source file: {path}"
    return path.read_text()


class NomadNetTextSelectionTests(unittest.TestCase):
    def test_wrapping_modes_enable_native_text_selection(self):
        source = _read(MICRON_DOC)
        # Selection is gated off in the UILabel-based scroll mode and on
        # elsewhere, so the modifier must reference isScrollMode.
        self.assertIn(".textSelection(isScrollMode ? .disabled : .enabled)", source)

    def test_monospace_lines_offer_long_press_copy_context_menu(self):
        source = _read(MICRON_LINE)
        self.assertIn("UIContextMenuInteraction", source)
        self.assertIn("UIContextMenuInteractionDelegate", source)
        self.assertIn("contextMenuInteraction(", source)
        # The single menu action copies the line text to the pasteboard.
        self.assertIn("UIPasteboard.general.string = text", source)
        self.assertIn('title: "Copy"', source)
        # An a11y identifier lets automation reach a specific line.
        self.assertIn('"nomadnet_line"', source)

    def test_copy_page_toolbar_action_copies_plain_text(self):
        source = _read(BROWSER_VIEW)
        self.assertIn("Copy Page", source)
        self.assertIn("copyPage()", source)
        # Copy Page reads the document's plain text, not the address.
        self.assertIn("viewModel.currentDocument?.plainText", source)
        # The pasteboard write is shared by Copy Address and Copy Page.
        self.assertIn("UIPasteboard.general.string = text", source)

    def test_plain_text_accessor_exists_on_model(self):
        source = _read(MICRON_MODEL)
        self.assertIn("var plainText: String", source)
        # Links render as their visible label, not their URL.
        self.assertIn("link.label", source)
        # Interactive form fields are not page prose and are excluded.
        self.assertIn(".formField", source)


if __name__ == "__main__":
    unittest.main()
