#if COLUMBA_NOMADNET_ENABLED
import Foundation
import RNSAPI

/// Parses micron markup text into a structured MicronDocument.
public struct MicronParser {

    public static func parse(_ markup: String) -> MicronDocument {
        let lines = markup.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var headers = MicronPageHeaders()
        var elements: [MicronElement] = []
        var lineIndex = 0
        var inLiteral = false
        var literalLines: [String] = []
        var literalIndent = 0
        var currentIndent = 0
        var currentAlignment: MicronAlignment = .left
        // Formatting state persists across lines (matches python NomadNet's
        // MicronParser, where `!/`*/`_/`Fxxx/`FTxxxxxx/`Bxxx/`BTxxxxxx are document-scoped until
        // toggled off or reset). Without this the chat-room page's
        // `F0ff`B52f preamble drops its colors before the ASCII art.
        var currentStyle: MicronTextStyle = .plain

        // Parse headers from top of document
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            if line.hasPrefix("#!") {
                parseHeader(line, into: &headers)
                lineIndex += 1
            } else {
                break
            }
        }

        // Process remaining lines
        lineLoop: while lineIndex < lines.count {
            var line = lines[lineIndex]
            lineIndex += 1

            // Literal content is opaque. Only an exact toggle closes the block;
            // reset and heading markers inside it remain literal text.
            if inLiteral {
                if line == "`=" {
                    elements.append(.literalBlock(
                        text: literalLines.joined(separator: "\n"),
                        indentLevel: literalIndent
                    ))
                    literalLines = []
                    inLiteral = false
                } else {
                    literalLines.append(line)
                }
                continue
            }

            // Canonical NomadNet recursively reparses a line whenever a reset or
            // field-bearing heading sanitization exposes a new block control.
            classificationLoop: while true {
                while line.first == "<" {
                    currentIndent = 0
                    line.removeFirst()
                    if line.isEmpty { continue lineLoop }
                }

                // A reset can expose a literal toggle, for example `<`=`.
                if line == "`=" {
                    inLiteral = true
                    literalIndent = currentIndent
                    continue lineLoop
                }

                // Empty line
                if line.isEmpty {
                    elements.append(.paragraph(
                        spans: [.text("", .plain)],
                        alignment: currentAlignment,
                        indentLevel: currentIndent
                    ))
                    continue lineLoop
                }

                // A heading containing fields is treated as a regular content
                // line. Stripping the heading markers can expose any other block
                // control, so restart classification from the beginning.
                if line.first == ">" && line.contains("`<") {
                    line.removeFirst(line.prefix(while: { $0 == ">" }).count)
                    continue classificationLoop
                }

                let firstChar = line.first!

                // Comment
                if firstChar == "#" {
                    continue lineLoop
                }

                // Heading
                if firstChar == ">" {
                    let level = line.prefix(while: { $0 == ">" }).count
                    currentIndent = max(0, (level - 1) * 2)
                    let content = String(line.dropFirst(level))
                    if content.isEmpty {
                        continue lineLoop
                    }
                    // Heading palette state is temporary in NomadNet. Inline
                    // formatting may style the heading and change alignment, but
                    // it must not inherit or mutate document text formatting.
                    let (spans, alignment, fields, _) = parseInline(
                        content,
                        currentStyle: .plain,
                        currentAlignment: currentAlignment
                    )
                    if let alignment = alignment { currentAlignment = alignment }
                    elements.append(.heading(level: level, spans: spans, alignment: currentAlignment))
                    for field in fields {
                        elements.append(.formField(field, indentLevel: currentIndent))
                    }
                    continue lineLoop
                }

                // Divider
                if firstChar == "-" {
                    let rest = line.dropFirst()
                    let requested = line.count == 2 ? rest.first : nil
                    let divChar: Character?
                    if let requested, requested.asciiValue.map({ $0 < 32 }) != true {
                        divChar = requested
                    } else {
                        divChar = nil
                    }
                    elements.append(.divider(character: divChar, indentLevel: currentIndent))
                    continue lineLoop
                }

                // Partial include: `{url`refresh`fields}
                if line.hasPrefix("`{") {
                    if let partial = parsePartial(line) {
                        elements.append(.partial(partial, indentLevel: currentIndent))
                    }
                    continue lineLoop
                }

                // Escaped line
                if firstChar == "\\" {
                    let text = String(line.dropFirst())
                    elements.append(.paragraph(
                        spans: [.text(text, currentStyle)],
                        alignment: currentAlignment,
                        indentLevel: currentIndent
                    ))
                    continue lineLoop
                }

                // Regular paragraph - parse inline formatting
                let (spans, alignment, fields, updatedStyle) = parseInline(
                    line,
                    currentStyle: currentStyle,
                    currentAlignment: currentAlignment
                )
                currentStyle = updatedStyle
                if let alignment = alignment { currentAlignment = alignment }
                elements.append(.paragraph(
                    spans: spans,
                    alignment: currentAlignment,
                    indentLevel: currentIndent
                ))
                for field in fields {
                    elements.append(.formField(field, indentLevel: currentIndent))
                }
                continue lineLoop
            }
        }

        // Close unclosed literal block
        if inLiteral && !literalLines.isEmpty {
            elements.append(.literalBlock(
                text: literalLines.joined(separator: "\n"),
                indentLevel: literalIndent
            ))
        }

        return MicronDocument(headers: headers, elements: elements)
    }

    // MARK: - Header Parsing

    private static func parseHeader(_ line: String, into headers: inout MicronPageHeaders) {
        let content = String(line.dropFirst(2)) // drop "#!"
        if content.hasPrefix("c=") {
            headers.cacheSeconds = Int(content.dropFirst(2))
        } else if content.hasPrefix("bg=") {
            headers.backgroundColor = String(content.dropFirst(3))
        } else if content.hasPrefix("fg=") {
            headers.foregroundColor = String(content.dropFirst(3))
        }
    }

    // MARK: - Inline Parsing

    /// Parse inline formatting within a line of text.
    /// Returns parsed spans, any alignment change detected, any form fields found,
    /// and the formatting style at the end of the line so callers can carry it
    /// forward (matches python NomadNet's document-scoped formatting state).
    private static func parseInline(
        _ text: String,
        currentStyle: MicronTextStyle,
        currentAlignment: MicronAlignment
    ) -> ([MicronSpan], MicronAlignment?, [MicronFormField], MicronTextStyle) {
        var spans: [MicronSpan] = []
        var style = currentStyle
        var alignment: MicronAlignment? = nil
        var formFields: [MicronFormField] = []
        var buffer = ""
        var i = text.startIndex

        func flushBuffer() {
            if !buffer.isEmpty {
                spans.append(.text(buffer, style))
                buffer = ""
            }
        }

        while i < text.endIndex {
            let ch = text[i]

            // Escape
            if ch == "\\" {
                let next = text.index(after: i)
                if next < text.endIndex {
                    buffer.append(text[next])
                    i = text.index(after: next)
                    continue
                }
            }

            // Backtick commands
            if ch == "`" {
                let next = text.index(after: i)
                guard next < text.endIndex else {
                    buffer.append(ch)
                    i = next
                    continue
                }

                let cmd = text[next]

                // Double backtick — reset all
                if cmd == "`" {
                    flushBuffer()
                    style = .plain
                    i = text.index(after: next)
                    continue
                }

                // Bold toggle
                if cmd == "!" {
                    flushBuffer()
                    style.bold.toggle()
                    i = text.index(after: next)
                    continue
                }

                // Italic toggle
                if cmd == "*" {
                    flushBuffer()
                    style.italic.toggle()
                    i = text.index(after: next)
                    continue
                }

                // Underline toggle
                if cmd == "_" {
                    flushBuffer()
                    style.underline.toggle()
                    i = text.index(after: next)
                    continue
                }

                // Foreground color: Fxxx (3-digit) or FTxxxxxx (true color)
                if cmd == "F" || cmd == "f" {
                    flushBuffer()
                    if cmd == "f" {
                        style.foregroundColor = nil
                        i = text.index(after: next)
                    } else {
                        let colorStart = text.index(after: next)
                        if let parsed = parseColor(in: text, from: colorStart) {
                            style.foregroundColor = parsed.value
                            i = parsed.endIndex
                        } else {
                            // Consume only the command. Preserve malformed or
                            // truncated payload text and leave the style intact.
                            i = colorStart
                        }
                    }
                    continue
                }

                // Background color: Bxxx (3-digit) or BTxxxxxx (true color)
                if cmd == "B" || cmd == "b" {
                    flushBuffer()
                    if cmd == "b" {
                        style.backgroundColor = nil
                        i = text.index(after: next)
                    } else {
                        let colorStart = text.index(after: next)
                        if let parsed = parseColor(in: text, from: colorStart) {
                            style.backgroundColor = parsed.value
                            i = parsed.endIndex
                        } else {
                            i = colorStart
                        }
                    }
                    continue
                }

                // Alignment
                if cmd == "c" {
                    flushBuffer()
                    alignment = .center
                    i = text.index(after: next)
                    continue
                }
                if cmd == "l" {
                    flushBuffer()
                    alignment = .left
                    i = text.index(after: next)
                    continue
                }
                if cmd == "r" {
                    flushBuffer()
                    alignment = .right
                    i = text.index(after: next)
                    continue
                }
                if cmd == "a" {
                    flushBuffer()
                    alignment = .left
                    i = text.index(after: next)
                    continue
                }

                // Link: `[label`url] or `[label`url`fields]
                if cmd == "[" {
                    flushBuffer()
                    if let link = parseLink(text, from: text.index(after: next)) {
                        spans.append(.link(link.link))
                        i = link.endIndex
                    } else {
                        buffer.append(ch)
                        i = next
                    }
                    continue
                }

                // Form field: `<spec`value>
                if cmd == "<" {
                    flushBuffer()
                    if let result = parseFormField(text, from: text.index(after: next)) {
                        // Form fields are returned as a special span that the
                        // caller should extract — but since they're block-level
                        // elements we handle them by returning early
                        formFields.append(result.field)
                        i = result.endIndex
                    } else {
                        buffer.append(ch)
                        i = next
                    }
                    continue
                }

                // Unknown command — treat as literal
                buffer.append(ch)
                i = next
                continue
            }

            buffer.append(ch)
            i = text.index(after: i)
        }

        flushBuffer()
        return (spans, alignment, formFields, style)
    }

    private struct ParsedColor {
        let value: String
        let endIndex: String.Index
    }

    /// Parse a Micron color payload starting immediately after F/B.
    /// `T` selects six-digit true color; otherwise the legacy three-digit
    /// form is used. Invalid payloads are rejected without consuming them.
    private static func parseColor(in text: String, from start: String.Index) -> ParsedColor? {
        guard start < text.endIndex else { return nil }

        let isTrueColor = text[start] == "T"
        let valueStart = isTrueColor ? text.index(after: start) : start
        let length = isTrueColor ? 6 : 3
        guard let valueEnd = text.index(valueStart, offsetBy: length, limitedBy: text.endIndex) else {
            return nil
        }

        let value = String(text[valueStart..<valueEnd])
        guard value.count == length, value.allSatisfy(\.isHexDigit) else { return nil }
        return ParsedColor(value: value.lowercased(), endIndex: valueEnd)
    }

    // MARK: - Form Field Parsing

    private struct ParsedFormField {
        let field: MicronFormField
        let label: String?
        let endIndex: String.Index
    }

    /// Parse a form field starting after the `<` character.
    /// Formats:
    ///   `<width|name`default>          — text input
    ///   `<!|name`default>              — password
    ///   `<?|name|value`>Label          — checkbox
    ///   `<?|name|value|*`>Label        — checkbox (prechecked)
    ///   `<^|name|value`>Label          — radio
    ///   `<^|name|value|*`>Label        — radio (preselected)
    private static func parseFormField(_ text: String, from start: String.Index) -> ParsedFormField? {
        // Find closing >
        guard let closeAngle = text[start...].firstIndex(of: ">") else { return nil }
        let content = String(text[start..<closeAngle])
        let afterClose = text.index(after: closeAngle)

        // Split on backtick to get spec and default value
        let backtickParts = content.split(separator: "`", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let spec = backtickParts[0]
        let defaultValue = backtickParts.count > 1 ? backtickParts[1] : ""

        // Split spec on pipe
        let specParts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard !specParts.isEmpty else { return nil }

        let typeIndicator = specParts[0]

        // Checkbox: ?|name|value or ?|name|value|*
        if typeIndicator == "?" && specParts.count >= 3 {
            let name = specParts[1]
            let value = specParts[2]
            let checked = specParts.count >= 4 && specParts[3] == "*"
            // Label follows the closing >
            let label = extractTrailingLabel(text, from: afterClose)
            return ParsedFormField(
                field: .checkbox(name: name, value: value, label: label.text, checked: checked),
                label: label.text,
                endIndex: label.endIndex
            )
        }

        // Radio: ^|name|value or ^|name|value|*
        if typeIndicator == "^" && specParts.count >= 3 {
            let name = specParts[1]
            let value = specParts[2]
            let selected = specParts.count >= 4 && specParts[3] == "*"
            let label = extractTrailingLabel(text, from: afterClose)
            return ParsedFormField(
                field: .radio(name: name, value: value, label: label.text, selected: selected),
                label: label.text,
                endIndex: label.endIndex
            )
        }

        // Password: !|name or !width|name
        if typeIndicator.hasPrefix("!") {
            let name = specParts.count >= 2 ? specParts[1] : typeIndicator.dropFirst().description
            return ParsedFormField(
                field: .passwordInput(name: name, defaultValue: defaultValue),
                label: nil,
                endIndex: afterClose
            )
        }

        // Text input: width|name or just name
        if specParts.count >= 2 {
            let width = Int(specParts[0]) ?? 24
            let name = specParts[1]
            return ParsedFormField(
                field: .textInput(width: width, name: name, defaultValue: defaultValue),
                label: nil,
                endIndex: afterClose
            )
        }

        // Single name, no width
        return ParsedFormField(
            field: .textInput(width: 24, name: typeIndicator, defaultValue: defaultValue),
            label: nil,
            endIndex: afterClose
        )
    }

    /// Extract label text that follows a checkbox/radio closing >.
    private static func extractTrailingLabel(_ text: String, from start: String.Index) -> (text: String, endIndex: String.Index) {
        // Label is the rest of the line after >
        let remaining = String(text[start...])
        return (remaining, text.endIndex)
    }

    // MARK: - Partial Parsing

    /// Parse a partial include line: `{url`refresh`fields}
    private static func parsePartial(_ line: String) -> MicronPartial? {
        // Strip `{ prefix and } suffix
        var content = line
        guard content.hasPrefix("`{") else { return nil }
        content = String(content.dropFirst(2))
        if content.hasSuffix("}") {
            content = String(content.dropLast())
        }

        let parts = content.split(separator: "`", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        let url = parts[0]
        var refreshInterval: Int? = nil
        var partialId: String? = nil
        var fieldNames: [String]? = nil

        if parts.count >= 2 && !parts[1].isEmpty {
            refreshInterval = Int(parts[1])
        }

        if parts.count >= 3 && !parts[2].isEmpty {
            let fields = parts[2].split(separator: "|").map(String.init)
            var names: [String] = []
            for field in fields {
                if field.hasPrefix("pid=") {
                    partialId = String(field.dropFirst(4))
                } else {
                    names.append(field)
                }
            }
            if !names.isEmpty { fieldNames = names }
        }

        return MicronPartial(
            url: url,
            refreshInterval: refreshInterval,
            partialId: partialId,
            fieldNames: fieldNames
        )
    }

    // MARK: - Link Parsing

    private struct ParsedLink {
        let link: MicronLink
        let endIndex: String.Index
    }

    /// Parse a link starting after the `[` character.
    /// Format: label`url] or label`url`fields]
    private static func parseLink(_ text: String, from start: String.Index) -> ParsedLink? {
        // Find closing ]
        guard let closeBracket = text[start...].firstIndex(of: "]") else { return nil }
        let content = String(text[start..<closeBracket])

        let parts = content.split(separator: "`", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)

        let label: String
        let urlString: String
        var fieldNames: [String]? = nil

        if parts.count >= 2 {
            label = parts[0]
            urlString = parts[1]
            if parts.count >= 3 && !parts[2].isEmpty {
                fieldNames = parts[2].split(separator: "|").map(String.init)
            }
        } else {
            label = content
            urlString = content
        }

        let url = parseURL(urlString)
        let endIndex = text.index(after: closeBracket)
        return ParsedLink(
            link: MicronLink(label: label, url: url, fieldNames: fieldNames),
            endIndex: endIndex
        )
    }

    // MARK: - URL Parsing

    /// Parse a NomadNet URL string into a MicronURL.
    public static func parseURL(_ urlString: String) -> MicronURL {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)

        // lxmf@hash
        if trimmed.hasPrefix("lxmf@") {
            return .lxmf(hash: String(trimmed.dropFirst(5)))
        }

        // Same-node path: starts with / or :
        if trimmed.hasPrefix("/") || trimmed.hasPrefix(":") {
            let path = trimmed.hasPrefix(":") ? String(trimmed.dropFirst()) : trimmed
            return .samePage(path: path)
        }

        // Remote node: hash:/path or just hash
        if let colonSlash = trimmed.range(of: ":/") {
            let hash = String(trimmed[trimmed.startIndex..<colonSlash.lowerBound])
            let path = String(trimmed[colonSlash.upperBound...])
            return .remoteNode(hash: hash, path: "/\(path)")
        }

        // Bare hash (no path) — default to index page
        if trimmed.allSatisfy({ $0.isHexDigit }) && trimmed.count >= 16 {
            return .remoteNode(hash: trimmed, path: "/page/index.mu")
        }

        // Fallback — treat as same-node path
        return .samePage(path: trimmed)
    }
}
#endif
