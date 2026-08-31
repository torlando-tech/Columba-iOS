#if COLUMBA_NOMADNET_ENABLED
import SwiftUI
import RNSAPI

// MARK: - Document

/// Parsed micron markup document.
public struct MicronDocument: Sendable, Equatable {
    public var headers: MicronPageHeaders
    public var elements: [MicronElement]

    public init(headers: MicronPageHeaders = MicronPageHeaders(), elements: [MicronElement] = []) {
        self.headers = headers
        self.elements = elements
    }
}

extension MicronDocument {
    /// Readable plain-text rendering of the page, in document order, for
    /// copy/share (the "Copy Page" toolbar action, issue #188).
    ///
    /// Mirrors what a user would see as text: headings and paragraphs emit
    /// their visible span text (links emit their label), literal blocks are
    /// preserved verbatim, dividers become a dashed line. Interactive form
    /// fields and async partials are excluded - they are not page prose.
    public var plainText: String {
        var lines: [String] = []
        for element in elements {
            switch element {
            case .heading(_, let spans, _),
                 .paragraph(let spans, _, _):
                let line = spans.map { span -> String in
                    switch span {
                    case .text(let content, _): return content
                    case .link(let link): return link.label
                    }
                }.joined()
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(line)
                }
            case .divider(_, _):
                lines.append("────────")
            case .literalBlock(let text, _):
                lines.append(text)
            case .formField(_, _), .partial(_, _):
                break
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Page Headers

public struct MicronPageHeaders: Sendable, Equatable {
    /// Cache duration in seconds. nil = default (12h), 0 = no cache.
    public var cacheSeconds: Int?
    /// Background color as legacy 3-digit hex (for example, "222").
    public var backgroundColor: String?
    /// Foreground color as legacy 3-digit hex (for example, "fff").
    public var foregroundColor: String?

    public init(cacheSeconds: Int? = nil, backgroundColor: String? = nil, foregroundColor: String? = nil) {
        self.cacheSeconds = cacheSeconds
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
    }
}

// MARK: - Elements

/// A block-level element in a parsed micron document.
///
/// Note: elements intentionally don't implement `Identifiable`. Two
/// identical dividers (`-`) or two identical headings would produce the
/// same ID, and `hashValue`-based IDs are randomized per-process. Callers
/// should iterate with `enumerated()` and use the offset as the `ForEach`
/// identifier, so position disambiguates repeats.
public enum MicronElement: Sendable, Equatable {
    case heading(level: Int, spans: [MicronSpan], alignment: MicronAlignment)
    case paragraph(spans: [MicronSpan], alignment: MicronAlignment, indentLevel: Int)
    case divider(character: Character?, indentLevel: Int)
    case literalBlock(text: String, indentLevel: Int)
    case formField(MicronFormField, indentLevel: Int)
    case partial(MicronPartial, indentLevel: Int)

    public var sectionIndent: Int {
        switch self {
        case .heading(let level, _, _):
            return max(0, (level - 1) * 2)
        case .paragraph(_, _, let indentLevel),
             .divider(_, let indentLevel),
             .literalBlock(_, let indentLevel),
             .formField(_, let indentLevel),
             .partial(_, let indentLevel):
            return indentLevel
        }
    }
}

// MARK: - Partials

/// Async sub-page include: `{url`refresh`fields}
public struct MicronPartial: Sendable, Equatable, Hashable {
    /// URL to fetch (same-node path or remote)
    public var url: String
    /// Auto-refresh interval in seconds (nil = no refresh, 0 = no refresh)
    public var refreshInterval: Int?
    /// Partial ID for targeted reloads via p:<pid> links
    public var partialId: String?
    /// Field names to include in partial requests
    public var fieldNames: [String]?
}

// MARK: - Form Fields

public enum MicronFormField: Sendable, Equatable, Hashable {
    /// Text input: `<width|name`defaultValue>
    case textInput(width: Int, name: String, defaultValue: String)
    /// Password input: `<!|name`defaultValue>
    case passwordInput(name: String, defaultValue: String)
    /// Checkbox: `<?|name|value`>Label  (* = prechecked)
    case checkbox(name: String, value: String, label: String, checked: Bool)
    /// Radio button: `<^|name|value`>Label  (* = preselected)
    case radio(name: String, value: String, label: String, selected: Bool)

    public var name: String {
        switch self {
        case .textInput(_, let name, _): return name
        case .passwordInput(let name, _): return name
        case .checkbox(let name, _, _, _): return name
        case .radio(let name, _, _, _): return name
        }
    }
}

// MARK: - Spans (inline content)

public enum MicronSpan: Sendable, Equatable, Hashable {
    case text(String, MicronTextStyle)
    case link(MicronLink)
}

// MARK: - Text Style

public struct MicronTextStyle: Sendable, Equatable, Hashable {
    public var bold: Bool = false
    public var italic: Bool = false
    public var underline: Bool = false
    public var foregroundColor: String?
    public var backgroundColor: String?

    public static let plain = MicronTextStyle()
}

// MARK: - Alignment

public enum MicronAlignment: Sendable, Equatable, Hashable {
    case left, center, right

    public var swiftUI: SwiftUI.Alignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    public var textAlignment: SwiftUI.TextAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

// MARK: - Links

public struct MicronLink: Sendable, Equatable, Hashable {
    public var label: String
    public var url: MicronURL
    public var fieldNames: [String]?
}

public enum MicronURL: Sendable, Equatable, Hashable {
    /// Same node, relative path (e.g. "/page/about.mu")
    case samePage(path: String)
    /// Different node (e.g. "a1b2c3d4e5f6:/page/index.mu")
    case remoteNode(hash: String, path: String)
    /// Open LXMF conversation (e.g. "lxmf@a1b2c3d4e5f6")
    case lxmf(hash: String)
}

// MARK: - Color Helpers

extension MicronTextStyle {
    /// Convert a legacy Micron 3-digit color to a SwiftUI Color.
    public static func colorFrom3Hex(_ hex: String) -> Color? {
        guard hex.count == 3 else { return nil }
        return colorFromExpandedHex(hex.map { String(repeating: $0, count: 2) }.joined())
    }

    /// Convert a parsed inline style color, including `FT`/`BT` true color.
    public static func colorFromStyleHex(_ hex: String) -> Color? {
        if hex.count == 3 { return colorFrom3Hex(hex) }
        guard hex.count == 6 else { return nil }
        return colorFromExpandedHex(hex)
    }

    private static func colorFromExpandedHex(_ expanded: String) -> Color? {
        guard expanded.allSatisfy(\.isHexDigit),
              let value = UInt32(expanded, radix: 16) else { return nil }
        let r = (value >> 16) & 0xFF
        let g = (value >> 8) & 0xFF
        let b = value & 0xFF
        return Color(
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0
        )
    }
}
#endif
