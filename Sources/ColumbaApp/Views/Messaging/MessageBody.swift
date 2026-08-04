import Foundation
import MarkdownUI
import RNSAPI
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
    let color: Color
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
    let color: Color
    let fontSize: CGFloat
    var onOpenLink: ((MessageLinkTarget) -> Void)?

    var body: some View {
        Group {
            switch renderer {
            case .markdown:
                MarkdownMessageText(
                    content: content,
                    color: color,
                    fontSize: fontSize
                )
                .accessibilityIdentifier("bubble_markdown")
            case .plain:
                PlainMessageText(
                    content: content,
                    color: color,
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
}

private struct MarkdownMessageText: View {
    let content: String
    let color: Color
    let fontSize: CGFloat
    @State private var parsedContent: MarkdownContent

    init(content: String, color: Color, fontSize: CGFloat) {
        self.content = content
        self.color = color
        self.fontSize = fontSize
        _parsedContent = State(initialValue: MarkdownContent(content))
    }

    var body: some View {
        Markdown(parsedContent)
            .markdownTheme(.basic)
            .markdownTextStyle {
                FontSize(fontSize)
                ForegroundColor(color)
            }
            .markdownTextStyle(\.link) {
                ForegroundColor(color)
                UnderlineStyle(.single)
            }
            .markdownImageProvider(BlockedMarkdownImageProvider())
            .markdownInlineImageProvider(BlockedMarkdownInlineImageProvider())
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: content) { _, newContent in
                parsedContent = MarkdownContent(newContent)
            }
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
