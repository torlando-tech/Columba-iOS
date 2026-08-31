#!/usr/bin/env python3
"""Behavioral contract: NomadNet browser text must be selectable and copyable
with the NATIVE selection UI (Android parity, issue #188).

Torlando's acceptance: long-press highlights text with two draggable handles
and the system context menu (Copy / Look Up / Translate / Share) - the same
behavior as the iOS message-bubble "Select Text" (SelectableMessageTextView).
The first implementation used a per-line UILabel + UIContextMenuInteraction
"Copy" action; that cannot produce selection handles or the system menu and
was rejected, so this contract pins the replacement:

  * ``MonospaceLineView.swift`` (the default ``.monospaceScroll`` mode) renders
    each text block as a non-editable, SELECTABLE ``UITextView``. Only
    ``UITextView.isSelectable`` surfaces the native two-handle selection UI;
    the per-line copy context menu must be gone.
  * ``MicronDocumentView.swift`` (the wrapping modes render real SwiftUI
    ``Text``) enables native long-press select/copy with ``.textSelection`` -
    but ONLY in the non-scroll modes.
  * ``NomadNetBrowserView.swift`` keeps a "Copy Page" toolbar action that
    copies the loaded page's readable plain text (``MicronDocument.plainText``)
    in every mode - the whole-page fallback.
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
    def test_monospace_blocks_use_selectable_uikitextview(self):
        source = _read(MICRON_LINE)
        # The block must be backed by a selectable UITextView: only that view
        # type surfaces the native long-press selection UI (highlight + two
        # draggable handles + system Copy/Look Up/Translate menu).
        self.assertIn("UITextView", source)
        self.assertIn("isSelectable = true", source)
        # It must be non-editable (selection only, no keyboard).
        self.assertIn("isEditable = false", source)
        # The block must not scroll on its own: the outer ZoomableScrollView
        # owns all scrolling.
        self.assertIn("isScrollEnabled = false", source)
        # An a11y identifier lets automation reach a specific block.
        self.assertIn('"nomadnet_line"', source)
        # The rejected per-line whole-line Copy context menu is gone.
        self.assertNotIn("UIContextMenuInteraction", source)
        self.assertNotIn("UIPasteboard.general.string", source)

    def test_monospace_block_links_use_native_link_attribute(self):
        source = _read(MICRON_LINE)
        # Links render through the native .link attribute (coexists with
        # long-press selection) and are routed back to the caller.
        self.assertIn(".link", source)
        self.assertIn("micron-link://", source)
        self.assertIn("shouldInteractWith", source)
        self.assertIn("onLinkTapped?(links[idx])", source)

    def test_wrapping_modes_enable_native_text_selection(self):
        source = _read(MICRON_DOC)
        # Selection is only applied in the wrapping modes: the body branches on
        # isScrollMode and applies .textSelection(.enabled) in the else branch.
        # (A single `.textSelection(x ? .disabled : .enabled)` ternary does not
        # compile - the two literals are unrelated types.)
        self.assertIn(".textSelection(.enabled)", source)
        self.assertIn("if isScrollMode {", source)

    def test_literal_blocks_are_one_multi_line_selectable_block(self):
        source = _read(MICRON_DOC)
        # A literal/code block is passed as a single MonospaceLineView with a
        # `lines:` array (one selectable region spanning all of its lines),
        # not a ForEach of per-line views.
        self.assertIn("lines: text.split(", source)
        self.assertIn("omittingEmptySubsequences: false", source)

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
