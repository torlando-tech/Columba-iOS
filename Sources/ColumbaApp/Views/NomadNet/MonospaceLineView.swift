#if COLUMBA_NOMADNET_ENABLED
import SwiftUI
import RNSAPI
#if os(iOS)
import UIKit
#endif

// MARK: - Text line

/// One line of page text inside a selectable run.
///
/// `spans` carry the inline content (text + links). `alignment` and
/// `indentLevel` are the line's layout attributes (nested sections indent
/// both sides in wrap mode and offset content in scroll mode). `colorOverride`
/// tints spans that have no explicit foreground color (used for wrap-mode
/// divider lines).
@available(iOS 17.0, macOS 14.0, *)
struct MicronTextLine: Equatable {
    var spans: [MicronSpan]
    var alignment: MicronAlignment = .left
    var indentLevel: Int = 0
    var colorOverride: Color? = nil
}

// MARK: - Selectable run view

/// Renders a run of text lines as ONE non-editable, selectable `UITextView`
/// (issue #188, Android parity).
///
/// One run is one selectable region. A long-press produces the native iOS
/// selection UI - highlighted text with two draggable handles and the system
/// Copy / Look Up / Translate / Share menu - exactly like the message
/// bubble's "Select Text" (`SelectableMessageTextView`). Because the WHOLE
/// run is a single `UITextView`, the two handles can be dragged ACROSS
/// newlines: a multi-line paragraph, an ASCII-art block, or a code block
/// selects as one unit. `MicronDocumentView` breaks a run only at headings
/// (full-width band), literal blocks (own band in wrap mode), form fields,
/// and partials, so interactive elements stay outside the selectable text.
///
/// Two earlier approaches were rejected: a per-line UILabel + whole-line
/// "Copy" context menu (no handles, not granular enough), and per-line
/// SwiftUI `Text` with native text-selection (on device it surfaced only a
/// "Copy | Share" menu, never the two-handle selection).
///
/// Scroll mode (`cellHeight != nil`): no wrapping, strict square cells
/// (minimum == maximum line height == `cellHeight`, zero line spacing) so
/// block-drawing characters stack tight. The container is at least the
/// viewport and wide enough that no line wraps. Centered/right-aligned lines
/// are positioned with an explicit per-line head indent computed against the
/// VIEWPORT (not the container width), so a wide line elsewhere in the run
/// never pushes centered content offscreen-right.
///
/// Wrap mode (`cellHeight == nil`): the container tracks the width proposed
/// by the enclosing container, lines wrap naturally with 2pt line spacing
/// (matching the previous per-line VStack spacing), and every line is
/// indented on head AND tail so nested sections keep both margins.
@available(iOS 17.0, macOS 14.0, *)
struct MonospaceLineView: View {
    let lines: [MicronTextLine]
    let fontSize: CGFloat
    let monospaced: Bool
    /// Width of one section-indent column (monospace char width, or 8pt in
    /// proportional mode - mirrors `MicronDocumentView.indentationWidth`).
    let indentUnit: CGFloat
    var bold: Bool = false
    var cellHeight: CGFloat? = nil
    var viewportWidth: CGFloat = 0
    var defaultForegroundColor: Color? = nil
    var linkForegroundColor: Color? = nil
    var onLinkTapped: ((MicronLink) -> Void)?

    init(
        lines: [MicronTextLine],
        fontSize: CGFloat,
        monospaced: Bool,
        indentUnit: CGFloat,
        bold: Bool = false,
        cellHeight: CGFloat? = nil,
        viewportWidth: CGFloat = 0,
        defaultForegroundColor: Color? = nil,
        linkForegroundColor: Color? = nil,
        onLinkTapped: ((MicronLink) -> Void)? = nil
    ) {
        self.lines = lines
        self.fontSize = fontSize
        self.monospaced = monospaced
        self.indentUnit = indentUnit
        self.bold = bold
        self.cellHeight = cellHeight
        self.viewportWidth = viewportWidth
        self.defaultForegroundColor = defaultForegroundColor
        self.linkForegroundColor = linkForegroundColor
        self.onLinkTapped = onLinkTapped
    }

    var body: some View {
        #if os(iOS)
        UISelectableTextRun(
            lines: lines,
            fontSize: fontSize,
            monospaced: monospaced,
            indentUnit: indentUnit,
            bold: bold,
            cellHeight: cellHeight,
            viewportWidth: viewportWidth,
            defaultForegroundColor: defaultForegroundColor,
            linkForegroundColor: linkForegroundColor,
            onLinkTapped: onLinkTapped
        )
        #else
        // Fallback for non-iOS platforms (the app is iOS-only; kept so the
        // file still compiles): plain text rows, not selectable.
        VStack(alignment: .leading, spacing: cellHeight != nil ? 0 : 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.spans.map { span -> String in
                    switch span {
                    case .text(let s, _): return s
                    case .link(let l): return l.label
                    }
                }.joined())
                .font(monospaced ? .system(size: fontSize, design: .monospaced) : .system(size: fontSize))
                .bold(bold)
                .lineLimit(cellHeight != nil ? 1 : nil)
                .frame(height: cellHeight, alignment: .leading)
            }
        }
        #endif
    }
}

#if os(iOS)

// MARK: - UIKit wrapper

/// A non-editable, selectable `UITextView` that renders a run of lines with
/// per-line paragraph styles. The native long-press selection (two handles +
/// system menu) comes from `UITextView.isSelectable`.
@available(iOS 17.0, *)
private struct UISelectableTextRun: UIViewRepresentable {
    let lines: [MicronTextLine]
    let fontSize: CGFloat
    let monospaced: Bool
    let indentUnit: CGFloat
    let bold: Bool
    let cellHeight: CGFloat?
    let viewportWidth: CGFloat
    let defaultForegroundColor: Color?
    let linkForegroundColor: Color?
    let onLinkTapped: ((MicronLink) -> Void)?

    var isScroll: Bool { cellHeight != nil }

    /// Ordered link spans (document order). `micron-link://<index>` maps here.
    var links: [MicronLink] {
        lines.flatMap { line in
            line.spans.compactMap { span in
                if case .link(let l) = span { return l }
                return nil
            }
        }
    }

    /// Advance width of one character in this run's base (regular, non-bold)
    /// font. Monospace variants share one advance, so bold/italic do not
    /// change it; this is only used to measure scroll-mode content width.
    var advance: CGFloat {
        let font = monospaced
            ? MicronRenderStyle.uiMonospaceFont(fontSize: fontSize)
            : UIFont.systemFont(ofSize: fontSize)
        return ("M" as NSString).size(withAttributes: [.font: font]).width
    }

    /// Character count of a line's content (links count by label length).
    private func lineChars(_ line: MicronTextLine) -> Int {
        line.spans.reduce(0) { acc, span in
            switch span {
            case .text(let s, _): return acc + s.count
            case .link(let l): return acc + l.label.count
            }
        }
    }

    /// Content width of a line in scroll mode (no wrap): chars x advance.
    private func lineContentWidth(_ line: MicronTextLine) -> CGFloat {
        CGFloat(lineChars(line)) * advance
    }

    /// The left x where a line's content starts.
    ///
    /// Scroll mode: positioned against the VIEWPORT so a wide line elsewhere
    /// in the run never pushes centered/right content offscreen-right.
    /// Wrap mode: just the section head indent (Core Text alignment handles
    /// centering within the indented region).
    private func lineHeadIndent(_ line: MicronTextLine) -> CGFloat {
        let indent = CGFloat(line.indentLevel) * indentUnit
        guard isScroll else { return indent }
        let wc = lineContentWidth(line)
        switch line.alignment {
        case .left: return indent
        case .center: return max(0, viewportWidth / 2 - wc / 2)
        case .right: return max(0, viewportWidth - indent - wc)
        }
    }

    /// Scroll-mode container width: at least the viewport, and wide enough
    /// that no line wraps (each line needs its head indent plus its content).
    var scrollWidth: CGFloat {
        let widest = lines.map { line in
            lineHeadIndent(line) + lineContentWidth(line)
        }.max() ?? 0
        return max(viewportWidth, widest + 1)
    }

    /// Fallback width when SwiftUI proposes no width at all (unspecified):
    /// the widest line rendered without wrapping, plus both indents.
    var intrinsicWidth: CGFloat {
        let font = monospaced
            ? MicronRenderStyle.uiMonospaceFont(fontSize: fontSize)
            : UIFont.systemFont(ofSize: fontSize)
        let widest = lines.map { line in
            let text = line.spans.map { span -> String in
                switch span {
                case .text(let s, _): return s
                case .link(let l): return l.label
                }
            }.joined()
            let w = (text as NSString).size(withAttributes: [.font: font]).width
            return w + CGFloat(line.indentLevel) * 2 * indentUnit
        }.max() ?? 0
        return max(1, widest + 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        // isSelectable (not isEditable) is what surfaces the native
        // selection UI: long-press -> highlight + two draggable handles +
        // the system Copy/Look Up/Translate/Share menu.
        textView.isSelectable = true
        // The outer container (ZoomableScrollView / SwiftUI ScrollView) owns
        // all scrolling; this run must not scroll on its own (no nested
        // scrolling, no clipping).
        textView.isScrollEnabled = false
        textView.isOpaque = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.contentInsetAdjustmentBehavior = .never
        textView.allowsEditingTextAttributes = false
        // Automation target only. Do NOT set accessibilityLabel: the default
        // label is the run's text, which is what VoiceOver must announce.
        textView.accessibilityIdentifier = "nomadnet_line"
        textView.delegate = context.coordinator
        // Populate immediately so the run is never blank if sizeThatFits is
        // deferred; sizeThatFits re-applies with the exact width.
        context.coordinator.apply(self, to: textView, width: isScroll ? scrollWidth : intrinsicWidth)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // Re-apply idempotently (no-op unless input or width changed).
        context.coordinator.apply(self, to: textView, width: textView.textContainer.size.width)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        if isScroll, let cellHeight {
            // Scroll mode: fixed intrinsic size (no wrapping).
            let width = scrollWidth
            context.coordinator.apply(self, to: uiView, width: width)
            return CGSize(width: width, height: CGFloat(lines.count) * cellHeight)
        }
        // Wrap mode: track the proposed width; rebuild the text when the
        // width changes (tail indents and wrapping depend on it).
        let width = max(1, proposal.width ?? intrinsicWidth)
        context.coordinator.apply(self, to: uiView, width: width)
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: height)
    }

    // MARK: - Attributed text

    func buildAttributes(width: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = monospaced
            ? MicronRenderStyle.uiMonospaceFont(fontSize: fontSize, bold: bold)
            : UIFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)

        var linkIndex = 0
        for (lineIndex, line) in lines.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            if isScroll, let cellHeight {
                // Strict square cell: block-drawing characters stack tight.
                paragraph.minimumLineHeight = cellHeight
                paragraph.maximumLineHeight = cellHeight
                paragraph.lineSpacing = 0
                // All scroll-mode lines are left-aligned and positioned by an
                // explicit head indent (see lineHeadIndent), so centered and
                // right-aligned content tracks the viewport, not the (possibly
                // much wider) container.
                paragraph.alignment = .left
                let head = lineHeadIndent(line)
                paragraph.firstLineHeadIndent = head
                paragraph.headIndent = head
                // Wide enough that the line never wraps (container width).
                paragraph.tailIndent = width
            } else {
                // Wrap mode: matches the 2pt between-line spacing the
                // previous per-line VStack produced. Core Text alignment
                // handles centering within the indented region.
                paragraph.alignment = uikitAlignment(line.alignment)
                paragraph.lineSpacing = 2
                let indent = CGFloat(line.indentLevel) * indentUnit
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent
                // Indent both sides so nested sections keep both margins.
                paragraph.tailIndent = max(indent, width - indent)
            }

            for span in line.spans {
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
                    } else if let colorOverride = line.colorOverride {
                        attrs[.foregroundColor] = UIColor(colorOverride)
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
                    // UITextViewDelegate.textView(_:shouldInteractWith:in:)
                    // and coexists with long-press text selection.
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
        if style.bold, !bold {
            font = monospaced
                ? MicronRenderStyle.uiMonospaceFont(fontSize: font.pointSize, bold: true)
                : UIFont.systemFont(ofSize: font.pointSize, weight: .bold)
        }
        if style.italic,
           let desc = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: desc, size: font.pointSize)
        }
        return font
    }

    private func uikitAlignment(_ alignment: MicronAlignment) -> NSTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onLinkTapped: ((MicronLink) -> Void)?
        var links: [MicronLink] = []

        private var lastLines: [MicronTextLine]?
        private var lastFontKey: (fontSize: CGFloat, monospaced: Bool, bold: Bool)?
        private var lastColors: (default: Color?, link: Color?)?
        private var lastWidth: CGFloat = 0
        private var lastIsScroll: Bool?

        /// Rebuilds the text view's content only when the run input or the
        /// container width changed (idempotent across layout passes).
        func apply(_ run: UISelectableTextRun, to textView: UITextView, width: CGFloat) {
            let isScroll = run.cellHeight != nil
            let fontKey = (fontSize: run.fontSize, monospaced: run.monospaced, bold: run.bold)
            let colors = (default: run.defaultForegroundColor, link: run.linkForegroundColor)
            // If everything matches what was already applied, this is a
            // no-op layout pass. (Tuples need no optional promotion, so the
            // stored values are unwrapped first.)
            if let lastLines, let lastFontKey, let lastColors {
                if run.lines == lastLines
                    && fontKey == lastFontKey
                    && colors == lastColors
                    && width == lastWidth
                    && isScroll == lastIsScroll {
                    return
                }
            }
            lastLines = run.lines
            lastFontKey = fontKey
            lastColors = colors
            lastWidth = width
            lastIsScroll = isScroll

            // The text container can be rebuilt on some iOS versions;
            // re-assert the zero padding so the left edge and no-wrap width
            // stay exact.
            textView.textContainer.lineFragmentPadding = 0
            let effectiveWidth = max(1, width)
            textView.textContainer.widthTracksTextView = false
            if isScroll, let cellHeight = run.cellHeight {
                textView.textContainer.size = CGSize(
                    width: effectiveWidth,
                    height: CGFloat(run.lines.count) * cellHeight
                )
            } else {
                textView.textContainer.size = CGSize(
                    width: effectiveWidth,
                    height: .greatestFiniteMagnitude
                )
            }
            textView.attributedText = run.buildAttributes(width: effectiveWidth)
            onLinkTapped = run.onLinkTapped
            links = run.links
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
