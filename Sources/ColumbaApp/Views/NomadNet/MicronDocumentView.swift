#if COLUMBA_NOMADNET_ENABLED
import SwiftUI
import RNSAPI

/// Renders a parsed MicronDocument as SwiftUI views.
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
    /// Viewport width for the SCROLL mode. Each row gets at least this width so
    /// `\`c`/`\`r` alignment centers/right-aligns content relative to the screen,
    /// not the document's max line width. Mirrors Android's
    /// `Modifier.widthIn(min = viewportLineWidth)` (NomadNetBrowserScreen.kt:474).
    /// Without this, a single wide row (e.g. the chat-room's 550-char trailing-
    /// whitespace line) sets the VStack width and centered shorter rows end up
    /// scrolled offscreen-right.
    var viewportWidth: CGFloat = 0
    var appliesDocumentPadding = true
    var partialAncestry: Set<String> = []

    var body: some View {
        // Android parity (#188): page text must be selectable/copyable.
        // `.textSelection` only reaches SwiftUI `Text`, so it is applied in
        // the wrapping modes (real Text) and NOT in `.monospaceScroll`
        // (UIKit UILabels, which get a long-press "Copy" context menu in
        // MonospaceLineView instead; the toolbar "Copy Page" covers all).
        if isScrollMode {
            documentContent
        } else {
            documentContent
                .textSelection(.enabled)
        }
    }

    /// The rendered document content, shared by both selection strategies.
    private var documentContent: some View {
        VStack(alignment: .leading, spacing: isScrollMode ? 0 : 2) {
            ForEach(Array(document.elements.enumerated()), id: \.offset) { index, element in
                renderElement(element, index: index)
            }
        }
        .padding(.horizontal, appliesDocumentPadding && !isScrollMode ? 12 : 0)
        .padding(.vertical, appliesDocumentPadding && !isScrollMode ? 8 : 0)
    }

    private var isScrollMode: Bool { style == .monospaceScroll }

    /// Exact pixel-grid cell height for square rendering of block-drawing characters.
    private var cellHeight: CGFloat { style.approxCharWidth * 2 }

    private var bodyFont: Font {
        style.swiftUIFont
    }

    @ViewBuilder
    private func renderElement(_ element: MicronElement, index: Int) -> some View {
        switch element {
        case .heading(let level, let spans, let alignment):
            let palette = MicronHeadingPalette.style(level: level, colorScheme: colorScheme)
            if isScrollMode {
                // UIKit-backed line with strict paragraph line-height so block chars stack tight
                MonospaceLineView(
                    spans: spans,
                    fontSize: style.fontSize,
                    cellHeight: cellHeight,
                    alignment: alignment,
                    bold: true,
                    defaultForegroundColor: palette.foreground,
                    linkForegroundColor: palette.foreground,
                    onLinkTapped: onLinkTapped
                )
                .padding(.leading, headingIndentWidth(level: level))
                .frame(minWidth: viewportWidth, alignment: alignment.swiftUI)
                .background(palette.background)
            } else {
                renderSpans(
                    spans,
                    onLinkTapped: onLinkTapped,
                    linkForegroundColor: palette.foreground
                )
                    .font(headingFont(level: level))
                    .bold()
                    .foregroundStyle(palette.foreground)
                    .padding(.leading, headingIndentWidth(level: level))
                    .frame(maxWidth: .infinity, alignment: alignment.swiftUI)
                    .background(palette.background)
                    .padding(.top, level == 1 ? 12 : 8)
                    .padding(.bottom, 4)
            }

        case .paragraph(let spans, let alignment, let indentLevel):
            if isScrollMode {
                MonospaceLineView(
                    spans: spans,
                    fontSize: style.fontSize,
                    cellHeight: cellHeight,
                    alignment: alignment,
                    bold: false,
                    onLinkTapped: onLinkTapped
                )
                .frame(
                    minWidth: sectionViewportWidth(columns: indentLevel),
                    alignment: alignment.swiftUI
                )
                .padding(.horizontal, indentationWidth(columns: indentLevel))
            } else {
                renderSpans(spans, onLinkTapped: onLinkTapped)
                    .font(bodyFont)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: alignment.swiftUI)
                    .padding(.horizontal, indentationWidth(columns: indentLevel))
            }

        case .divider(let character, let indentLevel):
            if isScrollMode {
                // Use a full-width horizontal line character for scroll mode
                let divChar = character.map(String.init) ?? "─"
                let dividerCount = viewportWidth > 0
                    ? max(1, Int(sectionViewportWidth(columns: indentLevel) / style.approxCharWidth))
                    : 80
                MonospaceLineView(
                    spans: [.text(String(repeating: divChar, count: dividerCount), .plain)],
                    fontSize: style.fontSize,
                    cellHeight: cellHeight,
                    alignment: .left,
                    bold: false,
                    onLinkTapped: nil
                )
                .frame(
                    minWidth: sectionViewportWidth(columns: indentLevel),
                    alignment: .leading
                )
                .padding(.horizontal, indentationWidth(columns: indentLevel))
            } else if let ch = character {
                Text(String(repeating: ch, count: 40))
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, indentationWidth(columns: indentLevel))
            } else {
                Divider()
                    .padding(.vertical, 4)
                    .padding(.horizontal, indentationWidth(columns: indentLevel))
            }

        case .literalBlock(let text, let indentLevel):
            if isScrollMode {
                // Split literal blocks into individual lines so each gets exact cell height
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        MonospaceLineView(
                            spans: [.text(String(line), .plain)],
                            fontSize: style.fontSize,
                            cellHeight: cellHeight,
                            alignment: .left,
                            bold: false,
                            onLinkTapped: nil
                        )
                    }
                }
                .padding(.horizontal, indentationWidth(columns: indentLevel))
            } else {
                Text(text)
                    .font(bodyFont)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.platformSystemGray6)
                    .cornerRadius(6)
                    .padding(.vertical, 4)
                    .padding(.horizontal, indentationWidth(columns: indentLevel))
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
                    viewportWidth: sectionViewportWidth(columns: indentLevel),
                    appliesDocumentPadding: false,
                    partialAncestry: partialAncestry.union([key])
                )
            )
        } else if loadingPartials.contains(key) {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading...")
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Form Field Rendering

    @ViewBuilder
    private func renderFormField(_ field: MicronFormField) -> some View {
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

    private func checkboxBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { checkboxFields[key] ?? false },
            set: { checkboxFields[key] = $0 }
        )
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        default: return .title3
        }
    }

    private func indentationWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * (style.usesMonospace ? style.approxCharWidth : 8)
    }

    private func headingIndentWidth(level: Int) -> CGFloat {
        indentationWidth(columns: max(0, (level - 1) * 2))
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

// MARK: - Span Rendering

/// Renders an array of MicronSpans into a single wrapping Text view.
///
/// Uses `AttributedString` with inline `.link` attributes so SwiftUI can
/// wrap naturally at word boundaries. Link taps are intercepted via a
/// custom URL scheme (`micron-link://<index>`) that `OpenURLAction` maps
/// back to the originating `MicronLink`.
@available(iOS 17.0, macOS 14.0, *)
func renderSpans(
    _ spans: [MicronSpan],
    onLinkTapped: ((MicronLink) -> Void)?,
    linkForegroundColor: Color? = nil
) -> some View {
    MicronSpansText(
        spans: spans,
        onLinkTapped: onLinkTapped,
        linkForegroundColor: linkForegroundColor
    )
}

@available(iOS 17.0, macOS 14.0, *)
struct MicronSpansText: View {
    let spans: [MicronSpan]
    var onLinkTapped: ((MicronLink) -> Void)?
    var linkForegroundColor: Color? = nil

    var body: some View {
        Text(buildAttributed())
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "micron-link",
                   let host = url.host,
                   let idx = Int(host),
                   idx < links.count {
                    onLinkTapped?(links[idx])
                    return .handled
                }
                return .systemAction
            })
    }

    /// Indices of link spans, in document order. The attributed string uses
    /// `micron-link://<index>` so the openURL handler can route back to the
    /// exact span without relying on label uniqueness.
    private var links: [MicronLink] {
        spans.compactMap { span in
            if case .link(let link) = span { return link }
            return nil
        }
    }

    private func buildAttributed() -> AttributedString {
        var result = AttributedString("")
        var linkIndex = 0
        for span in spans {
            switch span {
            case .text(let content, let style):
                result.append(styledAttributed(content, style: style))
            case .link(let link):
                var piece = AttributedString(link.label)
                piece.foregroundColor = linkForegroundColor ?? .accentColor
                piece.underlineStyle = .single
                if let url = URL(string: "micron-link://\(linkIndex)") {
                    piece.link = url
                }
                result.append(piece)
                linkIndex += 1
            }
        }
        return result
    }

    private func styledAttributed(_ content: String, style: MicronTextStyle) -> AttributedString {
        var piece = AttributedString(content)
        var intents: InlinePresentationIntent = []
        if style.bold { intents.insert(.stronglyEmphasized) }
        if style.italic { intents.insert(.emphasized) }
        if !intents.isEmpty { piece.inlinePresentationIntent = intents }
        if style.underline { piece.underlineStyle = .single }
        if let fg = style.foregroundColor, let color = MicronTextStyle.colorFromStyleHex(fg) {
            piece.foregroundColor = color
        }
        if let bg = style.backgroundColor, let color = MicronTextStyle.colorFromStyleHex(bg) {
            piece.backgroundColor = color
        }
        return piece
    }
}
#endif
