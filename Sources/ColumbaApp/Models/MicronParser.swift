import Foundation

/// Parses micron markup text into a structured MicronDocument.
public struct MicronParser {

    public static func parse(_ markup: String) -> MicronDocument {
        let lines = markup.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var headers = MicronPageHeaders()
        var elements: [MicronElement] = []
        var lineIndex = 0
        var inLiteral = false
        var literalLines: [String] = []
        var currentIndent = 0
        var currentAlignment: MicronAlignment = .left

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
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            lineIndex += 1

            // Literal block toggle
            if line.hasPrefix("`=") {
                if inLiteral {
                    elements.append(.literalBlock(text: literalLines.joined(separator: "\n")))
                    literalLines = []
                    inLiteral = false
                } else {
                    inLiteral = true
                }
                continue
            }

            if inLiteral {
                literalLines.append(line)
                continue
            }

            // Empty line
            if line.isEmpty {
                elements.append(.paragraph(spans: [.text("", .plain)], alignment: currentAlignment, indentLevel: currentIndent))
                continue
            }

            let firstChar = line.first!

            // Comment
            if firstChar == "#" {
                continue
            }

            // Heading
            if firstChar == ">" {
                let level = line.prefix(while: { $0 == ">" }).count
                let headingLevel = min(level, 3)
                currentIndent = headingLevel
                let content = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                if content.isEmpty {
                    continue
                }
                let (spans, alignment) = parseInline(content, currentStyle: .plain, currentAlignment: currentAlignment)
                if let alignment = alignment { currentAlignment = alignment }
                elements.append(.heading(level: headingLevel, spans: spans, alignment: currentAlignment))
                continue
            }

            // Divider
            if firstChar == "-" {
                let rest = line.dropFirst()
                let divChar: Character? = rest.isEmpty ? nil : rest.first
                elements.append(.divider(character: divChar))
                continue
            }

            // Reset indent
            if firstChar == "<" {
                currentIndent = 0
                let rest = String(line.dropFirst())
                if !rest.isEmpty {
                    let (spans, alignment) = parseInline(rest, currentStyle: .plain, currentAlignment: currentAlignment)
                    if let alignment = alignment { currentAlignment = alignment }
                    elements.append(.paragraph(spans: spans, alignment: currentAlignment, indentLevel: currentIndent))
                }
                continue
            }

            // Escaped line
            if firstChar == "\\" {
                let text = String(line.dropFirst())
                elements.append(.paragraph(spans: [.text(text, .plain)], alignment: currentAlignment, indentLevel: currentIndent))
                continue
            }

            // Regular paragraph — parse inline formatting
            let (spans, alignment) = parseInline(line, currentStyle: .plain, currentAlignment: currentAlignment)
            if let alignment = alignment { currentAlignment = alignment }
            elements.append(.paragraph(spans: spans, alignment: currentAlignment, indentLevel: currentIndent))
        }

        // Close unclosed literal block
        if inLiteral && !literalLines.isEmpty {
            elements.append(.literalBlock(text: literalLines.joined(separator: "\n")))
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
    /// Returns parsed spans and any alignment change detected.
    private static func parseInline(
        _ text: String,
        currentStyle: MicronTextStyle,
        currentAlignment: MicronAlignment
    ) -> ([MicronSpan], MicronAlignment?) {
        var spans: [MicronSpan] = []
        var style = currentStyle
        var alignment: MicronAlignment? = nil
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

                // Foreground color
                if cmd == "F" || cmd == "f" {
                    flushBuffer()
                    if cmd == "f" {
                        style.foregroundColor = nil
                        i = text.index(after: next)
                    } else {
                        // Read 3 hex digits
                        let colorStart = text.index(after: next)
                        if let colorEnd = text.index(colorStart, offsetBy: 3, limitedBy: text.endIndex) {
                            style.foregroundColor = String(text[colorStart..<colorEnd])
                            i = colorEnd
                        } else {
                            i = text.index(after: next)
                        }
                    }
                    continue
                }

                // Background color
                if cmd == "B" || cmd == "b" {
                    flushBuffer()
                    if cmd == "b" {
                        style.backgroundColor = nil
                        i = text.index(after: next)
                    } else {
                        let colorStart = text.index(after: next)
                        if let colorEnd = text.index(colorStart, offsetBy: 3, limitedBy: text.endIndex) {
                            style.backgroundColor = String(text[colorStart..<colorEnd])
                            i = colorEnd
                        } else {
                            i = text.index(after: next)
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

                // Unknown command — treat as literal
                buffer.append(ch)
                i = next
                continue
            }

            buffer.append(ch)
            i = text.index(after: i)
        }

        flushBuffer()
        return (spans, alignment)
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
