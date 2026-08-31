#if COLUMBA_NOMADNET_ENABLED
import SwiftUI
import RNSAPI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Renders one or more lines of monospace content as a single **selectable**
/// block (issue #188, Android parity).
///
/// Backed by a non-editable, selectable ``UITextView`` so a long-press produces
/// the native iOS selection UI - highlighted text with two draggable handles and
/// the system Copy / Look Up / Translate / Share menu - exactly like the message
/// bubble's "Select Text" (``SelectableMessageTextView``). A ``UILabel`` (the
/// earlier backing) cannot expose that selection UI, which is why the per-line
/// "Copy" context menu was replaced: whole-line copy was not granular enough.
///
/// A single paragraph or heading is one line; a literal/code block is several
/// lines rendered as one block, so selection (and its two handles) can span
/// multiple lines of code.
///
/// Rendering keeps the strict square-cell paragraph style (minimum == maximum
/// line height == ``cellHeight``, zero line spacing) so block-drawing characters
/// (▀▄█) stack tight, and each block is sized to its content so lines never wrap
/// (this mode is no-wrap). Links render via the native ``.link`` attribute and
/// are routed back to the caller through ``onLinkTapped``; they coexist with
/// long-press selection.
@available(iOS 17.0, macOS 14.0, *)
struct MonospaceLineView: View {
    let lines: [[MicronSpan]]
    let fontSize: CGFloat
    let cellHeight: CGFloat
    let alignment: MicronAlignment
    let bold: Bool
    var defaultForegroundColor: Color? = nil
    var linkForegroundColor: Color? = nil
    var onLinkTapped: ((MicronLink) -> Void)?

    /// Primary initializer: one selectable block per element, where a literal
    /// code block passes all of its lines at once (so selection can span the
    /// block) and a heading/paragraph passes a single line.
    init(
        lines: [[MicronSpan]],
        fontSize: CGFloat,
        cellHeight: CGFloat,
        alignment: MicronAlignment,
        bold: Bool,
        defaultForegroundColor: Color? = nil,
        linkForegroundColor: Color? = nil,
        onLinkTapped: ((MicronLink) -> Void)? = nil
    ) {
        self.lines = lines
        self.fontSize = fontSize
        self.cellHeight = cellHeight
        self.alignment = alignment
        self.bold = bold
        self.defaultForegroundColor = defaultForegroundColor
        self.linkForegroundColor = linkForegroundColor
        self.onLinkTapped = onLinkTapped
    }

    /// Single-line convenience (headings, paragraphs, dividers).
    init(
        spans: [MicronSpan],
        fontSize: CGFloat,
        cellHeight: CGFloat,
        alignment: MicronAlignment,
        bold: Bool,
        defaultForegroundColor: Color? = nil,
        linkForegroundColor: Color? = nil,
        onLinkTapped: ((MicronLink) -> Void)? = nil
    ) {
        self.init(
            lines: [spans],
            fontSize: fontSize,
            cellHeight: cellHeight,
            alignment: alignment,
            bold: bold,
            defaultForegroundColor: defaultForegroundColor,
            linkForegroundColor: linkForegroundColor,
            onLinkTapped: onLinkTapped
        )
    }

    var body: some View {
        #if os(iOS)
        UISelectableMonospaceBlock(
            lines: lines,
            fontSize: fontSize,
            cellHeight: cellHeight,
            alignment: alignment,
            bold: bold,
            defaultForegroundColor: defaultForegroundColor,
            linkForegroundColor: linkForegroundColor,
            onLinkTapped: onLinkTapped
        )
        #else
        // macOS fallback — plain Text rows with manual spacing (gaps may be
        // visible on macOS; the selectable behavior is iOS-only).
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, spans in
                Text(spans.map { span -> String in
                    switch span {
                    case .text(let s, _): return s
                    case .link(let l): return l.label
                    }
                }.joined())
                .font(.system(size: fontSize, design: .monospaced))
                .lineLimit(1)
                .frame(height: cellHeight, alignment: alignment.swiftUI)
            }
        }
        #endif
    }
}

#if os(iOS)

/// UIKit wrapper: a non-editable, selectable ``UITextView`` that renders
/// monospace lines with a strict square-cell paragraph style. The native
/// long-press selection (two handles + system menu) comes from
/// ``UITextView/isSelectable``.
@available(iOS 17.0, *)
private struct UISelectableMonospaceBlock: UIViewRepresentable {
    let lines: [[MicronSpan]]
    let fontSize: CGFloat
    let cellHeight: CGFloat
    let alignment: MicronAlignment
    let bold: Bool
    var defaultForegroundColor: Color? = nil
    var linkForegroundColor: Color? = nil
    var onLinkTapped: ((MicronLink) -> Void)?

    /// Ordered link spans (document order). ``micron-link://<index>`` maps here.
    private var links: [MicronLink] {
        lines.flatMap { line in
            line.compactMap { span in
                if case .link(let l) = span { return l }
                return nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLinkTapped: onLinkTapped, links: links)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        // isSelectable (not isEditable) is what surfaces the native selection
        // UI: long-press -> highlight + two draggable handles + system menu.
        textView.isSelectable = true
        // The outer ZoomableScrollView owns all scrolling; this block must not
        // scroll on its own (no nested scrolling, no clipping).
        textView.isScrollEnabled = false
        textView.isOpaque = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.contentInsetAdjustmentBehavior = .never
        // Automation target only. Do NOT set accessibilityLabel: the default
        // label is the block's text, which is what VoiceOver must announce.
        textView.accessibilityIdentifier = "nomadnet_line"
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // The text container can be rebuilt on some iOS versions; re-assert the
        // zero padding so the left edge and no-wrap width stay exact.
        textView.textContainer.lineFragmentPadding = 0
        let attr = buildAttributedString()
        if textView.text != attr.string {
            textView.attributedText = attr
        }
        context.coordinator.links = links
        context.coordinator.onLinkTapped = onLinkTapped
    }

    /// Intrinsic size of the block: as wide as its longest line (so no line
    /// wraps - this mode is no-wrap) and exactly one ``cellHeight`` tall per
    /// line. The SwiftUI call site wraps this in `.frame(minWidth:alignment:)`
    /// for centering / right-alignment of narrow rows, mirroring the previous
    /// label behavior and Android's `widthIn(min = viewportLineWidth)`.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = contentWidth()
        let height = CGFloat(lines.count) * cellHeight
        return CGSize(width: width, height: height)
    }

    // MARK: - Attributed text

    private func buildAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = cellHeight
        paragraph.maximumLineHeight = cellHeight
        paragraph.lineSpacing = 0
        paragraph.lineHeightMultiple = 0
        // Always render content left-aligned within the text view. SwiftUI
        // `.frame(alignment:)` at the call site handles visual centering /
        // right-alignment for narrow rows. This avoids Core Text's
        // trailing-whitespace stripping under .center / .right alignment.
        paragraph.alignment = .left

        let baseFont = MicronRenderStyle.uiMonospaceFont(
            fontSize: fontSize,
            bold: bold
        )

        var linkIndex = 0
        for (lineIndex, line) in lines.enumerated() {
            for span in line {
                switch span {
                case .text(let text, let style):
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: font(for: style, base: baseFont),
                        .paragraphStyle: paragraph,
                    ]
                    if let fg = style.foregroundColor,
                       let color = MicronTextStyle.colorFromStyleHex(fg) {
                        attrs[.foregroundColor] = UIColor(color)
                    } else if let defaultForegroundColor {
                        attrs[.foregroundColor] = UIColor(defaultForegroundColor)
                    } else {
                        attrs[.foregroundColor] = UIColor.label
                    }
                    if let bg = style.backgroundColor,
                       let color = MicronTextStyle.colorFromStyleHex(bg) {
                        attrs[.backgroundColor] = UIColor(color)
                    }
                    if style.underline {
                        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    result.append(NSAttributedString(string: text, attributes: attrs))

                case .link(let link):
                    // Native .link: a tap routes through
                    // UITextViewDelegate.textView(_:shouldInteractWith:in:) and
                    // coexists with long-press text selection.
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: baseFont,
                        .paragraphStyle: paragraph,
                        .foregroundColor: UIColor(linkForegroundColor ?? .accentColor),
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                    if let url = URL(string: "micron-link://\(linkIndex)") {
                        attrs[.link] = url
                    }
                    result.append(NSAttributedString(string: link.label, attributes: attrs))
                    linkIndex += 1
                }
            }
            if lineIndex < lines.count - 1 {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [.font: baseFont, .paragraphStyle: paragraph]
                ))
            }
        }
        return result
    }

    private func font(for style: MicronTextStyle, base: UIFont) -> UIFont {
        var font = base
        if style.bold {
            font = MicronRenderStyle.uiMonospaceFont(
                fontSize: base.pointSize,
                bold: true
            )
        }
        if style.italic,
           let desc = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: desc, size: font.pointSize)
        }
        return font
    }

    /// Rendered width of the widest line. The font is monospace, so a line's
    /// width is its character count times the advance (the existing metric test
    /// pins the rendered advance to `approxCharWidth`). The advance is measured
    /// with the same regular font `approxCharWidth` uses, plus 1pt of headroom
    /// so the longest line never wraps on sub-pixel rounding.
    private func contentWidth() -> CGFloat {
        let baseFont = MicronRenderStyle.uiMonospaceFont(fontSize: fontSize)
        let advance = ("M" as NSString).size(withAttributes: [.font: baseFont]).width
        let maxChars = lines.map { line in
            line.reduce(0) { acc, span in
                switch span {
                case .text(let s, _): return acc + s.count
                case .link(let l): return acc + l.label.count
                }
            }
        }.max() ?? 0
        return max(advance, CGFloat(maxChars) * advance + 1)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onLinkTapped: ((MicronLink) -> Void)?
        var links: [MicronLink]

        init(onLinkTapped: ((MicronLink) -> Void)?, links: [MicronLink]) {
            self.onLinkTapped = onLinkTapped
            self.links = links
            super.init()
        }

        /// Intercept our `micron-link://` links and route them to the caller.
        /// Returning `false` consumes the tap (no system URL open). Any other
        /// link is left to the system (there are none in practice).
        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange
        ) -> Bool {
            guard url.scheme == "micron-link",
                  let host = url.host,
                  let idx = Int(host),
                  idx < links.count
            else {
                return true
            }
            onLinkTapped?(links[idx])
            return false
        }
    }
}

#endif
#endif
