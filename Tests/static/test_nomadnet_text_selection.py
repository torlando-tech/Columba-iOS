#!/usr/bin/env python3
"""Behavioral contract: NomadNet browser text must be selectable and copyable
with the NATIVE selection UI (Android parity, issue #188).

Torlando's acceptance: long-press highlights text with two draggable handles
and the system context menu (Copy / Look Up / Translate / Share) - the same
behavior as the iOS message-bubble "Select Text" (SelectableMessageTextView).
Selection must span NEW LINES: the two handles must be draggable across
newlines, like Android's whole-page SelectionContainer.

Rejected earlier approaches:
  * per-line UILabel + UIContextMenuInteraction "Copy" action: no handles,
    whole-line only - not granular enough.
  * per-element selectable UITextView (one per line): the handles were
    trapped to a single line and could not cross newlines.
  * per-line SwiftUI Text + `.textSelection`: on the device it surfaced only
    a "Copy | Share" menu, never the two-handle selection.

This contract pins the replacement, which covers ALL THREE rendering modes:

  * ``MonospaceLineView.swift`` renders a run of lines as ONE non-editable,
    SELECTABLE ``UITextView``. Because the whole run is a single text view,
    the two selection handles can be dragged across newlines. Scroll mode
    keeps strict square cells (min == max line height == cellHeight, zero
    spacing) so block-drawing characters stack tight; centered/right-aligned
    lines are positioned against the VIEWPORT via per-line head indents.
  * ``MicronDocumentView.swift`` groups the document into runs: consecutive
    prose (paragraphs + dividers) merges into one selectable block; headings,
    literal blocks, form fields, and partials break the run so interactive
    elements stay outside the selectable text. Every mode renders text
    through the run view (no `.textSelection`).
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
    def test_runs_use_selectable_uikitextview(self):
        source = _read(MICRON_LINE)
        # The run must be backed by a selectable UITextView: only that view
        # type surfaces the native long-press selection UI (highlight + two
        # draggable handles + system Copy/Look Up/Translate menu).
        self.assertIn("UITextView", source)
        self.assertIn("isSelectable = true", source)
        # It must be non-editable (selection only, no keyboard).
        self.assertIn("isEditable = false", source)
        # The run must not scroll on its own: the outer container
        # (ZoomableScrollView / ScrollView) owns all scrolling.
        self.assertIn("isScrollEnabled = false", source)
        # An a11y identifier lets automation reach a specific run.
        self.assertIn('"nomadnet_line"', source)
        # The rejected per-line whole-line Copy context menu is gone.
        self.assertNotIn("UIContextMenuInteraction", source)
        self.assertNotIn("UIPasteboard.general.string", source)

    def test_cross_line_selection_via_single_run_textview(self):
        source = _read(MICRON_LINE)
        # Selection spans newlines because the whole run is ONE UITextView
        # (multiple lines joined by "\n" into one attributed string), not one
        # view per line.
        self.assertIn('string: "\\n"', source)
        # Scroll mode: strict square cells so block-drawing characters stack
        # tight (min == max line height, zero spacing).
        self.assertIn("minimumLineHeight = cellHeight", source)
        self.assertIn("maximumLineHeight = cellHeight", source)
        self.assertIn("lineSpacing = 0", source)
        # Centered/right-aligned scroll lines are positioned against the
        # viewport (per-line head indent), not the max line width.
        self.assertIn("viewportWidth / 2 - wc / 2", source)

    def test_run_links_use_native_link_attribute(self):
        source = _read(MICRON_LINE)
        # Links render through the native .link attribute (coexists with
        # long-press selection) and are routed back to the caller.
        self.assertIn(".link", source)
        self.assertIn("micron-link://", source)
        self.assertIn("shouldInteractWith", source)
        self.assertIn("onLinkTapped?(links[idx])", source)

    def test_document_groups_prose_into_selectable_runs(self):
        source = _read(MICRON_DOC)
        # Consecutive prose lines merge into one selectable run so the
        # selection handles span newlines.
        self.assertIn("case text([MicronTextLine])", source)
        self.assertIn("prose.append(MicronTextLine", source)
        # Headings and literal blocks break the run.
        self.assertIn("case .heading(let level, let spans, let alignment):", source)
        self.assertIn("case .literalBlock(let text, let indentLevel):", source)
        # Every rendering mode routes text through the selectable run view.
        self.assertIn("MonospaceLineView(", source)
        # The SwiftUI `.textSelection` path (which produced only a
        # "Copy | Share" menu on device, no handles) is gone from NomadNet.
        self.assertNotIn(".textSelection", source)

    def test_literal_blocks_are_one_multi_line_selectable_run(self):
        source = _read(MICRON_DOC)
        # A literal/code block becomes one run: its lines are split and each
        # becomes a MicronTextLine, so a long-press selects across the whole
        # block (handles span the newlines).
        self.assertIn('text.split(separator: "\\n", omittingEmptySubsequences: false)', source)
        self.assertIn("MicronTextLine(spans: [.text(String($0), .plain)]", source)

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
