#if COLUMBA_NOMADNET_ENABLED
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Render Container

/// Wraps MicronDocumentView in the appropriate scroll/zoom/wrap container for a given rendering mode.
@available(iOS 17.0, macOS 14.0, *)
struct MicronRenderContainer: View {
    let document: MicronDocument
    let mode: NomadNetRenderingMode
    @Binding var formFields: [String: String]
    @Binding var checkboxFields: [String: Bool]
    @Binding var radioFields: [String: String]
    var partialDocuments: [String: MicronDocument] = [:]
    var loadingPartials: Set<String> = []
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        switch mode {
        case .monospaceScroll:
            MonospaceScrollContainer(
                document: document,
                formFields: $formFields,
                checkboxFields: $checkboxFields,
                radioFields: $radioFields,
                partialDocuments: partialDocuments,
                loadingPartials: loadingPartials,
                onLinkTapped: onLinkTapped
            )

        case .monospaceZoom:
            ScrollView(.vertical) {
                MicronDocumentView(
                    document: document,
                    formFields: $formFields,
                    checkboxFields: $checkboxFields,
                    radioFields: $radioFields,
                    partialDocuments: partialDocuments,
                    loadingPartials: loadingPartials,
                    onLinkTapped: onLinkTapped,
                    style: .monospaceCompact
                )
            }

        case .proportionalWrap:
            ScrollView(.vertical) {
                MicronDocumentView(
                    document: document,
                    formFields: $formFields,
                    checkboxFields: $checkboxFields,
                    radioFields: $radioFields,
                    partialDocuments: partialDocuments,
                    loadingPartials: loadingPartials,
                    onLinkTapped: onLinkTapped,
                    style: .proportional
                )
            }
        }
    }
}

// MARK: - Monospace Scroll Container

/// Horizontal + vertical scroll with native pinch-to-zoom. Backed by
/// UIScrollView so pan, pinch, momentum, and bounce all work together —
/// SwiftUI's ScrollView + MagnifyGesture can't coordinate the two cleanly.
@available(iOS 17.0, macOS 14.0, *)
struct MonospaceScrollContainer: View {
    let document: MicronDocument
    @Binding var formFields: [String: String]
    @Binding var checkboxFields: [String: Bool]
    @Binding var radioFields: [String: String]
    var partialDocuments: [String: MicronDocument]
    var loadingPartials: Set<String>
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        #if os(iOS)
        ZoomableScrollView {
            MicronDocumentView(
                document: document,
                formFields: $formFields,
                checkboxFields: $checkboxFields,
                radioFields: $radioFields,
                partialDocuments: partialDocuments,
                loadingPartials: loadingPartials,
                onLinkTapped: onLinkTapped,
                style: .monospaceScroll
            )
            .fixedSize()
        }
        #else
        ScrollView([.horizontal, .vertical]) {
            MicronDocumentView(
                document: document,
                formFields: $formFields,
                checkboxFields: $checkboxFields,
                radioFields: $radioFields,
                partialDocuments: partialDocuments,
                loadingPartials: loadingPartials,
                onLinkTapped: onLinkTapped,
                style: .monospaceScroll
            )
            .fixedSize()
        }
        #endif
    }
}

// MARK: - Rendering Style

/// Style parameters used by MicronDocumentView. Picked based on rendering mode.
public enum MicronRenderStyle: Sendable, Equatable {
    /// Monospace, 14pt, square line height, no wrapping. For ASCII/pixel art.
    case monospaceScroll
    /// Monospace, 10pt, default line height, wrapping. Dense text.
    case monospaceCompact
    /// System font, 14pt, default line height, wrapping. Readable prose.
    case proportional

    public var fontSize: CGFloat {
        switch self {
        case .monospaceScroll: return 14
        case .monospaceCompact: return 10
        case .proportional: return 14
        }
    }

    public var usesMonospace: Bool {
        switch self {
        case .monospaceScroll, .monospaceCompact: return true
        case .proportional: return false
        }
    }

    public var wraps: Bool {
        switch self {
        case .monospaceScroll: return false
        case .monospaceCompact, .proportional: return true
        }
    }

    /// Measured width of a single character in the monospace font at this style's font size.
    /// Used to compute square line height for block-drawing characters (▀▄█ etc.).
    public var approxCharWidth: CGFloat {
        Self.measureMonospaceCharWidth(fontSize: fontSize)
    }

    /// Line spacing to apply for square pixel rendering.
    /// Returns 0 for modes that should use the system default.
    public var lineSpacing: CGFloat { 0 }

    /// Measure the advance width of a monospaced character at the given font size.
    /// Cached so we don't re-measure every frame.
    private static var charWidthCache: [CGFloat: CGFloat] = [:]

    private static func measureMonospaceCharWidth(fontSize: CGFloat) -> CGFloat {
        if let cached = charWidthCache[fontSize] { return cached }
        #if os(iOS)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        #elseif os(macOS)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        #else
        let width = fontSize * 0.6
        #endif
        charWidthCache[fontSize] = width
        return width
    }
}
#endif
