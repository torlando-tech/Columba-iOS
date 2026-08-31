#if COLUMBA_NOMADNET_ENABLED
import SwiftUI
import RNSAPI

/// Renders a parsed MicronDocument as SwiftUI views.
///
/// Android parity (#188): page text is selectable/copyable with the native
/// selection UI (highlight + two draggable handles + the system
/// Copy / Look Up / Translate / Share menu).
///
/// Text is rendered as one selectable `UITextView` PER RUN
/// (`MonospaceLineView`), where a run is a maximal stretch of consecutive
/// prose lines (paragraphs + dividers). Headings (full-width band),
/// literal blocks (own band in wrap mode), form fields, and partials each
/// break the run, so interactive elements stay outside the selectable text.
/// Because a run is a single `UITextView`, the two selection handles can be
/// dragged across newlines - a multi-line paragraph or code block selects as
/// one unit. The toolbar "Copy Page" remains a whole-page fallback in every
/// mode.
@available(iOS 17.0, macOS 14.0, *)
struct MicronDocumentView: View {
    @Environment(\.colorScheme) private var colorScheme
    let document: MicronDocument
    @Binding var formFields: [String: String]
    @Binding var checkboxFields: [String: Bool]
    @Binding var radioFields: [String: String]
    var partialDocuments: [String: MicronDocument] = [:]
    var loadingPartials: Set<String> = []
    var onLinkTapped: ((MicronLink) -> Void)?
    var style: MicronRenderStyle = .monospaceScroll
    /// Viewport width for the SCROLL mode. Each row gets at least this width
    /// so ``c``/``r`` alignment centers/right-aligns content relative to the
    /// screen, not the document's max line width. Mirrors Android's
    /// `Modifier.widthIn(min = viewportLineWidth)` (NomadNetBrowserScreen.kt:474).
    /// Without this, a single wide row (e.g. the chat-room's 550-char trailing-
    /// whitespace line) sets the VStack width and centered shorter rows end up
    /// scrolled offscreen-right.
    ///
    /// In the WRAP modes this value is not used: runs track the width proposed
    /// by the enclosing ScrollView (and fall back to their intrinsic
    /// width when no width is proposed), so long text wraps within the
    /// viewport.
    var viewportWidth: CGFloat = 0
    var appliesDocumentPadding = true
    var partialAncestry: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: isScrollMode ? 0 : 2) {
            ForEach(runs.indices, id: \.self) { index in
                renderRun(runs[index])
            }
        }
        // Wrap-mode document inset. In scroll mode the ZoomableScrollView owns
        // the layout (no inset); per-line indents handle section nesting.
        .padding(.horizontal, appliesDocumentPadding && !isScrollMode ? 12 : 0)
        .padding(.vertical, appliesDocumentPadding && !isScrollMode ? 8 : 0)
    }

    /// Width of one section-indent column (monospace char width, or 8pt in
    /// proportional mode - mirrors `indentationWidth`).
    private var indentUnit: CGFloat {
        style.usesMonospace ? style.approxCharWidth : 8
    }

    // MARK: - Run grouping

    enum Run {
        /// Consecutive prose lines (paragraphs + dividers), selectable as one
        /// unit so selection handles span newlines.
        case text([MicronTextLine])
        case heading(level: Int, spans: [MicronSpan], alignment: MicronAlignment)
        case literalBlock(text: String, indentLevel: Int)
        case formField(MicronFormField, indentLevel: Int)
        case partial(MicronPartial, indentLevel: Int)
    }

    /// Groups the document's elements into runs. A run of paragraphs and
    /// dividers merges into a single selectable text block; a heading,
    /// literal block, form field, or partial breaks the run (they get their
    /// own band in wrap mode, or stay interactive, respectively).
    private var runs: [Run] {
        var result: [Run] = []
        var prose: [MicronTextLine] = []
        func flush() {
            if !prose.isEmpty {
                result.append(.text(prose))
                prose = []
            }
        }
        for element in document.elements {
            switch element {
            case .heading(let level, let spans, let alignment):
                flush()
                result.append(.heading(level: level, spans: spans, alignment: alignment))
            case .paragraph(let spans, let alignment, let indentLevel):
                prose.append(MicronTextLine(spans: spans, alignment: alignment, indentLevel: indentLevel))
            case .divider(let character, let indentLevel):
                let count = isScrollMode
                    ? dividerCount(indentLevel: indentLevel)
                    : 40
                let divChar = character.map(String.init) ?? "─"
                prose.append(
                    MicronTextLine(
                        spans: [.text(String(repeating: divChar, count: count), .plain)],
                        alignment: .left,
                        indentLevel: indentLevel,
                        colorOverride: isScrollMode ? nil : .secondary
                    )
                )
            case .literalBlock(let text, let indentLevel):
                flush()
                result.append(.literalBlock(text: text, indentLevel: indentLevel))
            case .formField(let field, let indentLevel):
                flush()
                result.append(.formField(field, indentLevel: indentLevel))
            case .partial(let partial, let indentLevel):
                flush()
                result.append(.partial(partial, indentLevel: indentLevel))
            }
        }
        flush()
        return result
    }

    private var isScrollMode: Bool { style == .monospaceScroll }

    /// Exact pixel-grid cell height for square rendering of block-drawing
    /// characters (scroll mode only; wrap modes use `cellHeight = nil`).
    private var cellHeight: CGFloat? {
        isScrollMode ? style.approxCharWidth * 2 : nil
    }

    /// Divider line length in scroll mode: fill the section's available
    /// width (mirrors the previous per-line divider width).
    private func dividerCount(indentLevel: Int) -> Int {
        viewportWidth > 0
            ? max(1, Int(sectionViewportWidth(columns: indentLevel) / style.approxCharWidth))
            : 80
    }

    // MARK: - Run rendering

    @ViewBuilder
    private func renderRun(_ run: Run) -> some View {
        switch run {
        case .text(let lines):
            // A prose run: full-viewport container in scroll mode so the
            // per-line indents align centered/right content against the
            // screen; each line carries its own indent.
            MonospaceLineView(
                lines: lines,
                fontSize: style.fontSize,
                monospaced: style.usesMonospace,
                indentUnit: indentUnit,
                cellHeight: cellHeight,
                viewportWidth: isScrollMode ? viewportWidth : 0,
                onLinkTapped: onLinkTapped
            )

        case .heading(let level, let spans, let alignment):
            let palette = MicronHeadingPalette.style(level: level, colorScheme: colorScheme)
            let isScroll = isScrollMode
            // Headings: bold, and larger proportional title fonts in the wrap
            // modes (matching the previous .title/.title2/.title3); in scroll
            // mode the body monospace size, bold (the previous behavior).
            let headingFontSize: CGFloat = isScroll
                ? style.fontSize
                : headingSize(level: level)
            MonospaceLineView(
                lines: [MicronTextLine(
                    spans: spans,
                    alignment: alignment,
                    indentLevel: headingIndentLevel(level: level)
                )],
                fontSize: headingFontSize,
                monospaced: style.usesMonospace,
                indentUnit: indentUnit,
                bold: true,
                cellHeight: cellHeight,
                viewportWidth: isScroll ? viewportWidth : 0,
                defaultForegroundColor: palette.foreground,
                linkForegroundColor: palette.foreground,
                onLinkTapped: onLinkTapped
            )
            .background(palette.background)
            .padding(.top, isScroll ? 0 : (level == 1 ? 12 : 8))
            .padding(.bottom, isScroll ? 0 : 4)

        case .literalBlock(let text, let indentLevel):
            let literalLines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
                MicronTextLine(spans: [.text(String($0), .plain)], alignment: .left, indentLevel: indentLevel)
            }
            let block = MonospaceLineView(
                lines: literalLines,
                fontSize: style.fontSize,
                monospaced: style.usesMonospace,
                indentUnit: indentUnit,
                cellHeight: cellHeight,
                viewportWidth: isScrollMode ? viewportWidth : 0,
                onLinkTapped: nil
            )
            if isScrollMode {
                // No band in scroll mode: the code block sits on the page
                // background, indented by the per-line head/tail indent.
                block
            } else {
                // Wrap mode: a gray rounded band around the code, full width.
                block
                    .padding(8)
                    .background(Color.platformSystemGray6)
                    .cornerRadius(6)
                    .padding(.vertical, 4)
            }

        case .formField(let field, let indentLevel):
            renderFormField(field)
                .padding(.vertical, 2)
                .padding(.horizontal, indentationWidth(columns: indentLevel))

        case .partial(let partial, let indentLevel):
            renderPartial(partial, indentLevel: indentLevel)
                .padding(.horizontal, indentationWidth(columns: indentLevel))
        }
    }

    private func headingSize(level: Int) -> CGFloat {
        switch min(max(level, 1), 3) {
        case 1: return 28
        case 2: return 22
        default: return 20
        }
    }

    private func headingIndentLevel(level: Int) -> Int {
        max(0, (level - 1) * 2)
    }

    // MARK: - Partial Rendering

    @ViewBuilder
    private func renderPartial(_ partial: MicronPartial, indentLevel: Int) -> some View {
        let key = partial.partialId ?? partial.url
        if let partialDocument = partialDocuments[key], !partialAncestry.contains(key) {
            AnyView(
                MicronDocumentView(
                    document: partialDocument,
                    formFields: $formFields,
                    checkboxFields: $checkboxFields,
                    radioFields: $radioFields,
                    partialDocuments: partialDocuments,
                    loadingPartials: loadingPartials,
                    onLinkTapped: onLinkTapped,
                    style: style,
                    viewportWidth: isScrollMode ? sectionViewportWidth(columns: indentLevel) : 0,
                    appliesDocumentPadding: false,
                    partialAncestry: partialAncestry.union([key])
                )
            )
        } else if loadingPartials.contains(key) {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading...")
                    .font(style.swiftUIFont)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Form Field Rendering

    @ViewBuilder
    private func renderFormField(_ field: MicronFormField) -> some View {
        let bodyFont = style.swiftUIFont
        switch field {
        case .textInput(let width, let name, _):
            TextField(name, text: binding(for: name))
                .font(bodyFont)
                .textFieldStyle(.roundedBorder)
                .frame(
                    maxWidth: CGFloat(width) * (style.usesMonospace ? style.approxCharWidth : 10)
                )

        case .passwordInput(let name, _):
            SecureField(name, text: binding(for: name))
                .font(bodyFont)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

        case .checkbox(let name, let value, let label, _):
            let key = "\(name):\(value)"
            Button {
                checkboxFields[key] = !(checkboxFields[key] ?? false)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: (checkboxFields[key] ?? false) ? "checkmark.square.fill" : "square")
                        .foregroundColor((checkboxFields[key] ?? false) ? .accentColor : .secondary)
                    Text(label)
                        .font(bodyFont)
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)

        case .radio(let name, let value, let label, _):
            Button {
                radioFields[name] = value
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: radioFields[name] == value ? "circle.inset.filled" : "circle")
                        .foregroundColor(radioFields[name] == value ? .accentColor : .secondary)
                    Text(label)
                        .font(bodyFont)
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { formFields[name] ?? "" },
            set: { formFields[name] = $0 }
        )
    }

    private func indentationWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * (style.usesMonospace ? style.approxCharWidth : 8)
    }

    private func sectionViewportWidth(columns: Int) -> CGFloat {
        max(0, viewportWidth - (2 * indentationWidth(columns: columns)))
    }
}

private enum MicronHeadingPalette {
    static func style(level: Int, colorScheme: ColorScheme) -> (foreground: Color, background: Color) {
        let paletteLevel = min(max(level, 1), 3)
        let foregroundHex: String
        let backgroundHex: String

        if colorScheme == .dark {
            foregroundHex = ["222", "111", "000"][paletteLevel - 1]
            backgroundHex = ["bbb", "999", "777"][paletteLevel - 1]
        } else {
            foregroundHex = ["000", "111", "222"][paletteLevel - 1]
            backgroundHex = ["777", "aaa", "ccc"][paletteLevel - 1]
        }

        return (
            MicronTextStyle.colorFrom3Hex(foregroundHex) ?? .primary,
            MicronTextStyle.colorFrom3Hex(backgroundHex) ?? .clear
        )
    }
}
#endif
