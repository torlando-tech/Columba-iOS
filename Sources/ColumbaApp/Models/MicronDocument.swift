import SwiftUI

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

// MARK: - Page Headers

public struct MicronPageHeaders: Sendable, Equatable {
    /// Cache duration in seconds. nil = default (12h), 0 = no cache.
    public var cacheSeconds: Int?
    /// Background color as 3-digit hex (e.g. "222").
    public var backgroundColor: String?
    /// Foreground color as 3-digit hex (e.g. "fff").
    public var foregroundColor: String?

    public init(cacheSeconds: Int? = nil, backgroundColor: String? = nil, foregroundColor: String? = nil) {
        self.cacheSeconds = cacheSeconds
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
    }
}

// MARK: - Elements

public enum MicronElement: Sendable, Equatable, Identifiable {
    case heading(level: Int, spans: [MicronSpan], alignment: MicronAlignment)
    case paragraph(spans: [MicronSpan], alignment: MicronAlignment, indentLevel: Int)
    case divider(character: Character?)
    case literalBlock(text: String)
    case formField(MicronFormField)
    case partial(MicronPartial)

    public var id: String {
        switch self {
        case .heading(let level, let spans, _):
            return "h\(level)_\(spans.hashValue)"
        case .paragraph(let spans, _, let indent):
            return "p\(indent)_\(spans.hashValue)"
        case .divider(let ch):
            return "div_\(ch?.description ?? "default")"
        case .literalBlock(let text):
            return "lit_\(text.hashValue)"
        case .formField(let field):
            return "field_\(field.name)"
        case .partial(let partial):
            return "partial_\(partial.url)_\(partial.partialId ?? "auto")"
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
    /// Expand 3-digit hex to Color (each digit doubled: "d2f" → #DD22FF).
    public static func colorFrom3Hex(_ hex: String) -> Color? {
        guard hex.count == 3 else { return nil }
        let chars = Array(hex)
        guard let r = Int(String(repeating: chars[0], count: 2), radix: 16),
              let g = Int(String(repeating: chars[1], count: 2), radix: 16),
              let b = Int(String(repeating: chars[2], count: 2), radix: 16) else { return nil }
        return Color(
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0
        )
    }
}
