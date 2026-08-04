import Foundation
import MarkdownUI
import RNSAPI
import Splash
import SwiftUI

/// A message link after scheme validation and NomadNet address parsing.
enum MessageLinkTarget: Equatable, Hashable {
    case web(URL)
    case nomadNet(nodeHash: Data, path: String)
    case external(URL)

    var url: URL? {
        switch self {
        case .web(let url), .external(let url):
            return url
        case .nomadNet(let nodeHash, let path):
            let hash = nodeHash.map { String(format: "%02x", $0) }.joined()
            return URL(string: "nomadnetwork://\(hash):\(path)")
        }
    }
}

struct MessageLinkMatch: Equatable {
    let range: NSRange
    let text: String
    let target: MessageLinkTarget
}

/// Detects and validates the exact web and Reticulum links supported in message bodies.
enum MessageLinkParser {
    private static let bareNomadNetPattern =
        #"(?<![0-9a-fA-F])[0-9a-fA-F]{32}:/[^\s,;!?)\]]+(?<![.,;:])"#
    private static let explicitPattern =
        #"(?:https?|nomadnetwork|lxma)://[^\s,;!?)\]]+(?<![.,;:])"#
    private static let anchoredNomadNet = try! NSRegularExpression(
        pattern: #"^(?:nomadnetwork://)?([0-9a-fA-F]{32}):(/[^\s,;!?)\]]+)$"#,
        options: [.caseInsensitive]
    )
    private static let detectors = [
        try! NSRegularExpression(pattern: bareNomadNetPattern),
        try! NSRegularExpression(pattern: explicitPattern, options: [.caseInsensitive]),
    ]

    static func matches(in text: String) -> [MessageLinkMatch] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var candidates: [MessageLinkMatch] = []

        for detector in detectors {
            for result in detector.matches(in: text, range: fullRange) {
                guard let range = Range(result.range, in: text) else { continue }
                let raw = String(text[range])
                guard let target = target(for: raw) else { continue }
                candidates.append(MessageLinkMatch(range: result.range, text: raw, target: target))
            }
        }

        candidates.sort {
            if $0.range.location == $1.range.location {
                return $0.range.length > $1.range.length
            }
            return $0.range.location < $1.range.location
        }

        var resolved: [MessageLinkMatch] = []
        var lastEnd = 0
        for candidate in candidates where candidate.range.location >= lastEnd {
            resolved.append(candidate)
            lastEnd = candidate.range.location + candidate.range.length
        }
        return resolved
    }

    static func target(for url: URL) -> MessageLinkTarget? {
        target(for: url.absoluteString)
    }

    static func target(for rawValue: String) -> MessageLinkTarget? {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        if let match = anchoredNomadNet.firstMatch(in: cleaned, range: range),
           let hashRange = Range(match.range(at: 1), in: cleaned),
           let pathRange = Range(match.range(at: 2), in: cleaned),
           let hash = Data(hexString: String(cleaned[hashRange])) {
            return .nomadNet(nodeHash: hash, path: String(cleaned[pathRange]))
        }

        guard let url = URL(string: cleaned),
              let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return .web(url)
        case "lxma":
            return .external(url)
        default:
            return nil
        }
    }
}

struct PlainMessageText: View {
    let content: String
    let color: SwiftUI.Color
    let linkColor: SwiftUI.Color
    let fontSize: CGFloat

    var body: some View {
        Text(attributedContent)
            .font(.system(size: fontSize))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedContent: AttributedString {
        var output = AttributedString()
        let matches = MessageLinkParser.matches(in: content)
        var cursor = content.startIndex

        for match in matches {
            guard let range = Range(match.range, in: content) else { continue }
            if cursor < range.lowerBound {
                output += AttributedString(content[cursor..<range.lowerBound])
            }
            var linked = AttributedString(content[range])
            linked.link = match.target.url
            linked.foregroundColor = linkColor
            linked.underlineStyle = .single
            output += linked
            cursor = range.upperBound
        }
        if cursor < content.endIndex {
            output += AttributedString(content[cursor...])
        }
        return output
    }
}

struct MessageBody: View {
    let content: String
    let renderer: MessageRenderer
    let color: SwiftUI.Color
    let isOutgoing: Bool
    let fontSize: CGFloat
    var onOpenLink: ((MessageLinkTarget) -> Void)?

    var body: some View {
        Group {
            switch renderer {
            case .markdown:
                MarkdownMessageText(
                    content: content,
                    color: color,
                    isOutgoing: isOutgoing,
                    fontSize: fontSize
                )
                .accessibilityIdentifier("bubble_markdown")
            case .plain:
                PlainMessageText(
                    content: content,
                    color: color,
                    linkColor: linkColor,
                    fontSize: fontSize
                )
            }
        }
        .accessibilityIdentifier("bubble_text")
        .environment(\.openURL, OpenURLAction { url in
            guard let target = MessageLinkParser.target(for: url) else {
                return .discarded
            }
            switch target {
            case .web, .external:
                return .systemAction(url)
            case .nomadNet:
                guard let onOpenLink else { return .discarded }
                onOpenLink(target)
                return .handled
            }
        })
    }

    private var linkColor: SwiftUI.Color {
        isOutgoing
            ? SwiftUI.Color(red: 0.75, green: 0.91, blue: 1.0)
            : SwiftUI.Color(red: 0.25, green: 0.65, blue: 1.0)
    }
}

private struct MarkdownMessageText: View {
    let content: String
    let color: SwiftUI.Color
    let isOutgoing: Bool
    let fontSize: CGFloat
    @State private var parsedContent: MarkdownContent

    init(content: String, color: SwiftUI.Color, isOutgoing: Bool, fontSize: CGFloat) {
        self.content = content
        self.color = color
        self.isOutgoing = isOutgoing
        self.fontSize = fontSize
        _parsedContent = State(initialValue: MarkdownContent(content))
    }

    var body: some View {
        Markdown(parsedContent)
            .markdownTextStyle {
                FontSize(fontSize)
                ForegroundColor(color)
            }
            .markdownTextStyle(\.link) {
                ForegroundColor(linkColor)
                UnderlineStyle(.single)
            }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(fontSize * 0.85)
                ForegroundColor(color)
                BackgroundColor(inlineCodeBackground)
            }
            .markdownImageProvider(BlockedMarkdownImageProvider())
            .markdownInlineImageProvider(BlockedMarkdownInlineImageProvider())
            .markdownCodeSyntaxHighlighter(
                SplashCodeSyntaxHighlighter(
                    theme: .wwdc17(withFont: .init(size: fontSize * 0.85))
                )
            )
            .markdownBlockStyle(\.codeBlock) { configuration in
                codeBlock(configuration)
            }
            .markdownTheme(.basic)
            .onChange(of: content) { _, newContent in
                parsedContent = MarkdownContent(newContent)
            }
    }

    private func codeBlock(_ configuration: CodeBlockConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language = configuration.language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(
                        size: max(10, fontSize * 0.65),
                        weight: .semibold,
                        design: .monospaced
                    ))
                    .foregroundStyle(SwiftUI.Color.white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            ScrollView(.horizontal) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(fontSize * 0.82)
                    }
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(blockCodeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .markdownMargin(top: .em(0.25), bottom: .em(0.6))
    }

    private var linkColor: SwiftUI.Color {
        isOutgoing
            ? SwiftUI.Color(red: 0.75, green: 0.91, blue: 1.0)
            : SwiftUI.Color(red: 0.25, green: 0.65, blue: 1.0)
    }

    private var inlineCodeBackground: SwiftUI.Color {
        isOutgoing
            ? SwiftUI.Color.black.opacity(0.25)
            : SwiftUI.Color.white.opacity(0.16)
    }

    private var blockCodeBackground: SwiftUI.Color {
        SwiftUI.Color(red: 0.19, green: 0.20, blue: 0.23)
    }
}

struct BlockedMarkdownImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark")
            if let source = url?.host ?? url?.lastPathComponent,
               !source.isEmpty {
                Text(source)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(6)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct BlockedMarkdownInlineImageProvider: InlineImageProvider {
    enum Blocked: Error {
        case remoteImage
    }

    func image(with url: URL, label: String) async throws -> Image {
        throw Blocked.remoteImage
    }
}

private struct SplashCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private let syntaxHighlighter: SyntaxHighlighter<SplashTextOutputFormat>

    init(theme: Splash.Theme) {
        syntaxHighlighter = SyntaxHighlighter(format: SplashTextOutputFormat(theme: theme))
    }

    func highlightCode(_ content: String, language: String?) -> Text {
        guard language?.lowercased() == "swift" else {
            return Text(content)
        }
        return syntaxHighlighter.highlight(content)
    }
}

private struct SplashTextOutputFormat: OutputFormat {
    let theme: Splash.Theme

    func makeBuilder() -> Builder {
        Builder(theme: theme)
    }

    struct Builder: OutputBuilder {
        let theme: Splash.Theme
        private var fragments: [Text] = []

        init(theme: Splash.Theme) {
            self.theme = theme
        }

        mutating func addToken(_ token: String, ofType type: TokenType) {
            let tokenColor = theme.tokenColors[type] ?? theme.plainTextColor
            fragments.append(Text(token).foregroundColor(SwiftUI.Color(uiColor: tokenColor)))
        }

        mutating func addPlainText(_ text: String) {
            fragments.append(Text(text).foregroundColor(SwiftUI.Color(uiColor: theme.plainTextColor)))
        }

        mutating func addWhitespace(_ whitespace: String) {
            fragments.append(Text(whitespace))
        }

        func build() -> Text {
            fragments.reduce(Text(""), +)
        }
    }
}
