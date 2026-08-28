#!/usr/bin/env python3
"""Regression contract: the image-quality bottom sheet must not clip its
content at large Dynamic Type sizes (issue #181).

A user with enlarged accessibility text reported the image-quality bottom
sheet (shown after choosing a photo to attach) pushing its "Image Quality"
header off the top of the sheet and its Cancel/Attach action buttons off the
bottom of the screen. The sheet was pinned to a fixed 340pt detent with a
non-scrolling body, so once the rows grew with the text size the content
overflowed the sheet in both directions.

The fix (see MessagingView.swift):
  1. The sheet's detent height is a `@ScaledMetric` that grows in lockstep
     with the user's Dynamic Type size, so the sheet makes room for larger
     text instead of clipping it.
  2. The sheet's content is pinned to exactly that height with
     `.frame(height: sheetHeight)`. Without this the sheet proposes unbounded
     height to the content and clips both ends; with it, the header and the
     Cancel/Attach buttons stay pinned while the quality options scroll.
  3. The quality options live in a `ScrollView` so that at the largest text
     sizes the options scroll instead of pushing the action buttons off the
     screen.
  4. The sheet's view + closures live in the `imageQualityPickerSheet`
     computed property rather than inline in `MessagingView.body`: the body
     sits at the Swift type-checker's expression-complexity limit, and
     inlining the sheet's closures makes it fail with "unable to type-check
     in reasonable time".

This contract pins all four halves so the clipping (or the compile
regression) cannot silently return.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MESSAGING_VIEW = ROOT / "Sources/ColumbaApp/Views/Messaging/MessagingView.swift"


def _sheet_block(source: str, state_var: str) -> str:
    """Return the `.sheet(isPresented: $<state_var>) { ... }` modifier block.

    Bounded by the opening brace of the sheet content closure and the next
    `        }` line, so the assertions run against exactly this sheet.
    """
    marker = f".sheet(isPresented: ${state_var}) {{"
    start = source.find(marker)
    assert start != -1, f"could not find sheet for {state_var}"
    end = source.find("\n        }", start)
    assert end != -1, f"could not bound sheet for {state_var}"
    return source[start:end]


def _computed_property(source: str, name: str) -> str:
    """Return the `private var <name>: some View { ... }` property body."""
    start = source.find(f"private var {name}: some View {{")
    assert start != -1, f"computed property {name} not found"
    end = source.find("\n    }", start)
    assert end != -1, f"could not bound computed property {name}"
    return source[start:end + 6]


def _scaled_metric(source: str, name: str) -> str:
    """Return the `@ScaledMetric ... private var <name>: CGFloat = <n>` line."""
    idx = source.find(f"private var {name}: CGFloat")
    assert idx != -1, f"scaled metric {name} not found"
    # Back up to the @ScaledMetric attribute on the preceding line.
    line_start = source.rfind("\n", 0, idx) + 1
    attr_start = source.rfind("\n", 0, line_start - 1) + 1
    line_end = source.find("\n", idx)
    return source[attr_start:line_end + 1]


def _picker_body(source: str) -> str:
    """Return the `ImageQualityPickerSheet` struct body."""
    start = source.find("private struct ImageQualityPickerSheet")
    assert start != -1, "ImageQualityPickerSheet not found"
    end = source.find("// MARK: - UIImage Resize Helper", start)
    assert end != -1, "could not bound ImageQualityPickerSheet"
    return source[start:end]


class ImageQualitySheetDynamicSizeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = MESSAGING_VIEW.read_text(encoding="utf-8")

    def test_quality_sheet_height_is_dynamic_type_scaled(self) -> None:
        metric = _scaled_metric(self.source, "imageQualitySheetHeight")

        # The detent height must be a Dynamic Type-scaled metric so the sheet
        # grows to make room for larger text (the user's ask for a dynamic
        # sheet size).
        self.assertIn("@ScaledMetric", metric)
        self.assertIn("relativeTo:", metric)

        prop = _computed_property(self.source, "imageQualityPickerSheet")
        # The sheet must present with the scaled height, not a hard-coded
        # pixel constant.
        self.assertIn(".presentationDetents([.height(imageQualitySheetHeight)])", prop)
        self.assertNotIn(".height(340)", prop)
        # ...and the confirm/cancel actions must still be wired.
        self.assertIn("ImageQualityPickerSheet(", prop)
        self.assertIn("showQualityPicker = false", prop)

    def test_quality_sheet_is_extracted_out_of_body(self) -> None:
        # The body presents the sheet via the computed property (keeps the
        # body under the type-checker's complexity limit).
        block = _sheet_block(self.source, "showQualityPicker")
        self.assertIn("imageQualityPickerSheet", block)
        self.assertNotIn("ImageQualityPickerSheet(", block)

    def test_picker_options_scroll_and_header_buttons_stay_pinned(self) -> None:
        body = _picker_body(self.source)

        # The sheet's content must be pinned to exactly the (Dynamic-Type-
        # scaled) detent height. This is the half that actually stops the
        # clipping: without it the sheet proposes unbounded height and
        # overflows both ends (issue #181).
        self.assertIn(".frame(height: sheetHeight)", body)

        # The quality options are wrapped in a ScrollView so they can scroll
        # at very large text sizes instead of pushing the action buttons off
        # the screen.
        self.assertIn("ScrollView {", body)
        # ...and only bounce when they actually overflow, so at normal text
        # sizes the sheet is static (matches SyncStatusBottomSheet).
        self.assertIn(".scrollBounceBehavior(.basedOnSize)", body)

        # The header and the two action buttons remain real views (not moved
        # into the scrollable region), so they stay visible and tappable.
        self.assertIn('Text("Image Quality")', body)
        self.assertIn('Button("Cancel")', body)
        self.assertIn('Button("Attach")', body)


if __name__ == "__main__":
    unittest.main()
