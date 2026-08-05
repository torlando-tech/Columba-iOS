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

    var body: some View {
        VStack(alignment: .leading, spacing: isScrollMode ? 0 : 2) {
            ForEach(Array(document.elements.enumerated()), id: \.offset) { index, element in
                renderElement(element, index: index)
            }
        }
        .padding(.horizontal, isScrollMode ? 0 : 12)
        .padding(.vertical, isScrollMode ? 0 : 8)
    }

    private var isScrollMode: Bool { style == .monospaceScroll }

    /// Exact pixel-grid cell height for square rendering of block-drawing characters.
    private var cellHeight: CGFloat { style.approxCharWidth * 2 }

    private var bodyFont: Font {
        if style.usesMonospace {
            return .system(size: style.fontSize, design: .monospaced)
        } else {
            return .system(size: style.fontSize)
        }
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
                .padding(.leading, CGFloat(indentLevel) * style.approxCharWidth)
                .frame(minWidth: viewportWidth, alignment: alignment.swiftUI)
            } else {
                renderSpans(spans, onLinkTapped: onLinkTapped)
                    .font(bodyFont)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: alignment.swiftUI)
                    .padding(.leading, indentationWidth(columns: indentLevel))
            }

        case .divider(let character):
            if isScrollMode {
                // Use a full-width horizontal line character for scroll mode
                let divChar = character.map(String.init) ?? "─"
                MonospaceLineView(
                    spans: [.text(String(repeating: divChar, count: 80), .plain)],
                    fontSize: style.fontSize,
                    cellHeight: cellHeight,
                    alignment: .left,
                    bold: false,
                    onLinkTapped: nil
                )
                .frame(minWidth: viewportWidth, alignment: .leading)
            } else if let ch = character {
                Text(String(repeating: ch, count: 40))
                    .font(.system(size: style.fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                Divider()
                    .padding(.vertical, 4)
            }

        case .literalBlock(let text):
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
            } else {
                Text(text)
                    .font(.system(size: style.fontSize, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.platformSystemGray6)
                    .cornerRadius(6)
                    .padding(.vertical, 4)
            }

        case .formField(let field):
            renderFormField(field)
                .padding(.vertical, 2)

        case .partial(let partial):
            renderPartial(partial)
        }
    }

    // MARK: - Partial Rendering

    @ViewBuilder
    private func renderPartial(_ partial: MicronPartial) -> some View {
        let key = partial.partialId ?? partial.url
        MicronPartialView(
            partialKey: key,
            partialDocuments: partialDocuments,
            loadingPartials: loadingPartials,
            onLinkTapped: onLinkTapped
        )
    }

    // MARK: - Form Field Rendering

    @ViewBuilder
    private func renderFormField(_ field: MicronFormField) -> some View {
        switch field {
        case .textInput(let width, let name, _):
            TextField(name, text: binding(for: name))
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: CGFloat(width) * 10)

        case .passwordInput(let name, _):
            SecureField(name, text: binding(for: name))
                .font(.system(.body, design: .monospaced))
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
                        .font(.system(.body, design: .monospaced))
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
                        .font(.system(.body, design: .monospaced))
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
}

// MARK: - Partial View

/// Renders a loaded partial document inline, or a loading indicator.
@available(iOS 17.0, macOS 14.0, *)
private struct MicronPartialView: View {
    let partialKey: String
    let partialDocuments: [String: MicronDocument]
    let loadingPartials: Set<String>
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        if let partialDoc = partialDocuments[partialKey] {
            // Render partial content as simple text spans (no nested form/partial support)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(partialDoc.elements.enumerated()), id: \.offset) { _, element in
                    MicronSimpleElementView(element: element, onLinkTapped: onLinkTapped)
                }
            }
        } else if loadingPartials.contains(partialKey) {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading...")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

/// Simplified element renderer for partial content (no form fields or nested partials).
@available(iOS 17.0, macOS 14.0, *)
private struct MicronSimpleElementView: View {
    @Environment(\.colorScheme) private var colorScheme
    let element: MicronElement
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        switch element {
        case .heading(let level, let spans, let alignment):
            let palette = MicronHeadingPalette.style(level: level, colorScheme: colorScheme)
            renderSpans(
                spans,
                onLinkTapped: onLinkTapped,
                linkForegroundColor: palette.foreground
            )
                .font(.headline)
                .bold()
                .foregroundStyle(palette.foreground)
                .padding(.leading, CGFloat(max(0, (level - 1) * 2)) * 8)
                .frame(maxWidth: .infinity, alignment: alignment.swiftUI)
                .background(palette.background)
        case .paragraph(let spans, let alignment, let indentLevel):
            renderSpans(spans, onLinkTapped: onLinkTapped)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: alignment.swiftUI)
                .padding(.leading, CGFloat(indentLevel) * 8)
        case .divider:
            Divider().padding(.vertical, 4)
        case .literalBlock(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color.platformSystemGray6)
                .cornerRadius(6)
        case .formField, .partial:
            EmptyView()
        }
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
        if style.bold && style.italic {
            piece.font = .body.bold().italic()
        } else if style.bold {
            piece.font = .body.bold()
        } else if style.italic {
            piece.font = .body.italic()
        }
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
