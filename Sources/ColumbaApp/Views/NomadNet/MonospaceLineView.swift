import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Renders a single line of micron content with exact cell height,
/// no font leading/padding, and tight glyph stacking. This is the only
/// way to get block-drawing characters (▀▄█) to stack without gaps in
/// SwiftUI, since `.frame(height:)` crops but doesn't remove font leading.
///
/// Used only in monospaceScroll mode.
@available(iOS 17.0, macOS 14.0, *)
struct MonospaceLineView: View {
    let spans: [MicronSpan]
    let fontSize: CGFloat
    let cellHeight: CGFloat
    let alignment: MicronAlignment
    let bold: Bool
    var onLinkTapped: ((MicronLink) -> Void)?

    var body: some View {
        #if os(iOS)
        UIMonospaceLine(
            attributedString: buildAttributedString(),
            cellHeight: cellHeight,
            alignment: alignment,
            onTap: handleTap
        )
        .frame(height: cellHeight)
        #else
        // macOS fallback — plain Text with manual spacing (gaps may be visible on macOS)
        Text(spans.map { span -> String in
            switch span {
            case .text(let s, _): return s
            case .link(let l): return l.label
            }
        }.joined())
        .font(.system(size: fontSize, design: .monospaced))
        .lineLimit(1)
        .frame(height: cellHeight, alignment: alignment.swiftUI)
        #endif
    }

    #if os(iOS)
    private func buildAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = cellHeight
        paragraph.maximumLineHeight = cellHeight
        paragraph.lineSpacing = 0
        paragraph.lineHeightMultiple = 0
        switch alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }

        let baseFont: UIFont = {
            if bold {
                return UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            }
            return UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }()

        for span in spans {
            switch span {
            case .text(let text, let style):
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font(for: style, base: baseFont),
                    .paragraphStyle: paragraph,
                ]
                if let fg = style.foregroundColor,
                   let color = MicronTextStyle.colorFrom3Hex(fg) {
                    attrs[.foregroundColor] = UIColor(color)
                } else {
                    attrs[.foregroundColor] = UIColor.label
                }
                if let bg = style.backgroundColor,
                   let color = MicronTextStyle.colorFrom3Hex(bg) {
                    attrs[.backgroundColor] = UIColor(color)
                }
                if style.underline {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: text, attributes: attrs))

            case .link(let link):
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: baseFont,
                    .paragraphStyle: paragraph,
                    .foregroundColor: UIColor.tintColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: "columba-micron://link/\(result.length)",
                ]
                _ = attrs // mark the attribute so we can map back to MicronLink
                result.append(NSAttributedString(string: link.label, attributes: attrs))
            }
        }
        return result
    }

    private func font(for style: MicronTextStyle, base: UIFont) -> UIFont {
        var font = base
        if style.bold {
            font = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .bold)
        }
        if style.italic,
           let desc = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: desc, size: font.pointSize)
        }
        return font
    }

    private func handleTap(at index: Int) {
        // Find the link span whose label range contains this index
        var offset = 0
        for span in spans {
            switch span {
            case .text(let t, _):
                offset += t.count
            case .link(let link):
                let end = offset + link.label.count
                if index >= offset && index < end {
                    onLinkTapped?(link)
                    return
                }
                offset = end
            }
        }
    }
    #endif
}

#if os(iOS)

/// UIKit wrapper: a UILabel with strict line-height paragraph style.
@available(iOS 17.0, *)
private struct UIMonospaceLine: UIViewRepresentable {
    let attributedString: NSAttributedString
    let cellHeight: CGFloat
    let alignment: MicronAlignment
    var onTap: ((Int) -> Void)?

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.backgroundColor = .clear
        label.isUserInteractionEnabled = true
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:)))
        label.addGestureRecognizer(tap)
        context.coordinator.onTap = onTap
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.attributedText = attributedString
        context.coordinator.onTap = onTap
        switch alignment {
        case .left: uiView.textAlignment = .left
        case .center: uiView.textAlignment = .center
        case .right: uiView.textAlignment = .right
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var onTap: ((Int) -> Void)?

        @objc func didTap(_ sender: UITapGestureRecognizer) {
            guard let label = sender.view as? UILabel,
                  let attr = label.attributedText else { return }
            let location = sender.location(in: label)
            let index = characterIndex(at: location, in: label, attributedText: attr)
            if index != NSNotFound {
                onTap?(index)
            }
        }

        private func characterIndex(at location: CGPoint, in label: UILabel, attributedText: NSAttributedString) -> Int {
            let textContainer = NSTextContainer(size: label.bounds.size)
            textContainer.lineFragmentPadding = 0
            textContainer.lineBreakMode = label.lineBreakMode
            textContainer.maximumNumberOfLines = label.numberOfLines
            let layoutManager = NSLayoutManager()
            layoutManager.addTextContainer(textContainer)
            let textStorage = NSTextStorage(attributedString: attributedText)
            textStorage.addLayoutManager(layoutManager)

            let index = layoutManager.characterIndex(
                for: location,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            return index
        }
    }
}

#endif
