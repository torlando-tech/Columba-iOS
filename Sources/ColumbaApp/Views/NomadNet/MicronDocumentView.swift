import SwiftUI

/// Renders a parsed MicronDocument as SwiftUI views.
@available(iOS 17.0, macOS 14.0, *)
struct MicronDocumentView: View {
    let document: MicronDocument
    @Binding var formFields: [String: String]
    @Binding var checkboxFields: [String: Bool]
    @Binding var radioFields: [String: String]
    var partialDocuments: [String: MicronDocument] = [:]
    var loadingPartials: Set<String> = []
    var onLinkTapped: ((MicronLink) -> Void)?
    var style: MicronRenderStyle = .monospaceScroll

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(document.elements.enumerated()), id: \.offset) { index, element in
                renderElement(element, index: index)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

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
            renderSpans(spans, onLinkTapped: onLinkTapped)
                .font(headingFont(level: level))
                .bold()
                .lineSpacing(style.lineSpacing)
                .lineLimit(style.wraps ? nil : 1)
                .frame(maxWidth: style.wraps ? .infinity : nil, alignment: alignment.swiftUI)
                .padding(.top, level == 1 ? 12 : 8)
                .padding(.bottom, 4)

        case .paragraph(let spans, let alignment, let indentLevel):
            renderSpans(spans, onLinkTapped: onLinkTapped)
                .font(bodyFont)
                .lineSpacing(style.lineSpacing)
                .lineLimit(style.wraps ? nil : 1)
                .frame(maxWidth: style.wraps ? .infinity : nil, alignment: alignment.swiftUI)
                .padding(.leading, CGFloat(indentLevel) * 16)

        case .divider(let character):
            if let ch = character {
                Text(String(repeating: ch, count: 40))
                    .font(.system(size: style.fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: style.wraps ? .infinity : nil)
                    .padding(.vertical, 4)
            } else {
                Divider()
                    .padding(.vertical, 4)
            }

        case .literalBlock(let text):
            Text(text)
                .font(.system(size: style.fontSize, design: .monospaced))
                .lineLimit(style.wraps ? nil : nil) // literal blocks always preserve layout
                .padding(8)
                .frame(maxWidth: style.wraps ? .infinity : nil, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(6)
                .padding(.vertical, 4)

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
    let element: MicronElement
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        switch element {
        case .heading(_, let spans, let alignment):
            renderSpans(spans, onLinkTapped: onLinkTapped)
                .font(.headline)
                .bold()
                .frame(maxWidth: .infinity, alignment: alignment.swiftUI)
        case .paragraph(let spans, let alignment, let indentLevel):
            renderSpans(spans, onLinkTapped: onLinkTapped)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: alignment.swiftUI)
                .padding(.leading, CGFloat(indentLevel) * 16)
        case .divider:
            Divider().padding(.vertical, 4)
        case .literalBlock(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(6)
        case .formField, .partial:
            EmptyView()
        }
    }
}

// MARK: - Span Rendering

/// Renders an array of MicronSpans into a composed view.
/// Uses Text concatenation for styled text, and buttons for links.
@available(iOS 17.0, macOS 14.0, *)
@ViewBuilder
func renderSpans(_ spans: [MicronSpan], onLinkTapped: ((MicronLink) -> Void)?) -> some View {
    // Check if any spans are links — if so, use a flow layout
    let hasLinks = spans.contains { span in
        if case .link = span { return true }
        return false
    }

    if hasLinks {
        // Mixed text+links: wrap in an HStack-style layout
        WrappingHStack(spans: spans, onLinkTapped: onLinkTapped)
    } else {
        // Pure text: use Text concatenation for efficient rendering
        spans.reduce(Text("")) { result, span in
            switch span {
            case .text(let content, let style):
                return result + styledText(content, style: style)
            case .link(let link):
                return result + Text(link.label).foregroundColor(.accentColor).underline()
            }
        }
    }
}

/// Build a styled Text view from a MicronTextStyle.
private func styledText(_ content: String, style: MicronTextStyle) -> Text {
    var text = Text(content)
    if style.bold { text = text.bold() }
    if style.italic { text = text.italic() }
    if style.underline { text = text.underline() }
    if let fg = style.foregroundColor, let color = MicronTextStyle.colorFrom3Hex(fg) {
        text = text.foregroundColor(color)
    }
    return text
}

// MARK: - Wrapping HStack for mixed text+links

/// A simple wrapping layout for lines containing both text and tappable links.
@available(iOS 17.0, macOS 14.0, *)
private struct WrappingHStack: View {
    let spans: [MicronSpan]
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        // Use a simple approach: render each span inline
        HStack(spacing: 0) {
            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                switch span {
                case .text(let content, let style):
                    styledText(content, style: style)

                case .link(let link):
                    Button {
                        onLinkTapped?(link)
                    } label: {
                        Text(link.label)
                            .foregroundColor(.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
