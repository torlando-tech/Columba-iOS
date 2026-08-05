import XCTest
@testable import ColumbaApp
import RNSAPI
import LXMFSwift
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private actor RecordingNomadNetBackend: RnsNomadnet {
    struct Request: Sendable, Equatable {
        let destinationHash: String
        let path: String
        let requestData: [String: String]?
    }

    private var recordedRequests: [Request] = []

    func fetchNomadNetPage(
        destHashHex: String,
        path: String,
        timeout: TimeInterval,
        formFields: [String: String]?
    ) async throws -> NomadNetFetchResult {
        recordedRequests.append(Request(
            destinationHash: destHashHex,
            path: path,
            requestData: formFields
        ))
        return NomadNetFetchResult(
            ok: true,
            status: .ok,
            data: Data("# response for \(path)".utf8),
            contentType: "text/x-micron"
        )
    }

    func requests() -> [Request] { recordedRequests }
}

private actor ReactionGateProbe {
    private var active = 0
    private var maximumActive = 0

    func enter() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func leave() {
        active -= 1
    }

    func maximum() -> Int {
        maximumActive
    }
}

final class MicronParserTests: XCTestCase {

    // MARK: - Page Headers

    func testCacheHeader() {
        let doc = MicronParser.parse("#!c=300\nHello")
        XCTAssertEqual(doc.headers.cacheSeconds, 300)
    }

    func testNoCacheHeader() {
        let doc = MicronParser.parse("#!c=0\nHello")
        XCTAssertEqual(doc.headers.cacheSeconds, 0)
    }

    func testColorHeaders() {
        let doc = MicronParser.parse("#!bg=222\n#!fg=fff\nHello")
        XCTAssertEqual(doc.headers.backgroundColor, "222")
        XCTAssertEqual(doc.headers.foregroundColor, "fff")
    }

    func testMultipleHeaders() {
        let doc = MicronParser.parse("#!c=60\n#!bg=000\n#!fg=ddd\nContent")
        XCTAssertEqual(doc.headers.cacheSeconds, 60)
        XCTAssertEqual(doc.headers.backgroundColor, "000")
        XCTAssertEqual(doc.headers.foregroundColor, "ddd")
    }

    // MARK: - Headings

    func testHeadingLevel1() {
        let doc = MicronParser.parse(">Welcome")
        guard case .heading(let level, let spans, _) = doc.elements.first else {
            XCTFail("Expected heading"); return
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(spans.count, 1)
        if case .text(let text, _) = spans[0] {
            XCTAssertEqual(text, "Welcome")
        } else { XCTFail("Expected text span") }
    }

    func testHeadingLevel2() {
        let doc = MicronParser.parse(">>Subsection")
        guard case .heading(let level, _, _) = doc.elements.first else {
            XCTFail("Expected heading"); return
        }
        XCTAssertEqual(level, 2)
    }

    func testHeadingLevel3() {
        let doc = MicronParser.parse(">>>Deep")
        guard case .heading(let level, _, _) = doc.elements.first else {
            XCTFail("Expected heading"); return
        }
        XCTAssertEqual(level, 3)
    }

    func testSectionDepthIsNotCappedByThreeHeadingPaletteStyles() {
        let doc = MicronParser.parse(">>>>TooDeep")
        guard case .heading(let level, _, _) = doc.elements.first else {
            XCTFail("Expected heading"); return
        }
        XCTAssertEqual(level, 4)
    }

    func testRngitResetImmediatelyFollowedByReadmeHeadingReparsesRemainder() {
        // Current rngit repo pages join the template's trailing `<` directly
        // to a converted Markdown heading, producing this exact line shape.
        let doc = MicronParser.parse("<>The Non-linear Task Manager")

        guard case .heading(let level, let spans, _) = doc.elements.first,
              case .text(let text, _) = spans.first else {
            XCTFail("Expected reset remainder to be parsed as a heading")
            return
        }

        XCTAssertEqual(level, 1)
        XCTAssertEqual(text, "The Non-linear Task Manager")
    }

    func testSectionIndentUsesCanonicalTwoCellsPerNestedLevel() {
        let doc = MicronParser.parse("""
        >Top
        top body
        >>Nested
        nested body
        >>>>Deep
        deep body
        """)

        let paragraphIndents = doc.elements.compactMap { element -> Int? in
            guard case .paragraph(_, _, let indent) = element else { return nil }
            return indent
        }
        XCTAssertEqual(paragraphIndents, [0, 2, 6])
    }

    func testSectionResetEscapedRemainderPreservesFormattingState() {
        let doc = MicronParser.parse("`!bold\n<\\>literal")

        guard case .paragraph(let spans, _, let indent) = doc.elements.last,
              case .text(let text, let style) = spans.first else {
            XCTFail("Expected escaped reset remainder")
            return
        }

        XCTAssertEqual(text, ">literal")
        XCTAssertEqual(indent, 0)
        XCTAssertTrue(style.bold)
    }

    func testFieldBearingHeadingSanitizationRestartsBlockClassification() {
        let doc = MicronParser.parse(">># hidden `<name`value>")
        XCTAssertTrue(doc.elements.isEmpty)
    }

    func testResetRemainderCanOpenLiteralBlock() {
        let doc = MicronParser.parse("<`=\n<`=\n`=")
        guard case .literalBlock(let text, let indentLevel) = doc.elements.first else {
            XCTFail("Expected reset remainder to open a literal block")
            return
        }
        XCTAssertEqual(text, "<`=")
        XCTAssertEqual(indentLevel, 0)
    }

    func testFieldBearingHeadingSanitizationReclassifiesExposedReset() {
        let doc = MicronParser.parse("><# hidden `<name`value>")
        XCTAssertTrue(doc.elements.isEmpty)
    }

    func testNestedBlocksCarryCanonicalSectionIndent() {
        let doc = MicronParser.parse("""
        >>Nested
        -X
        `=
        literal
        `=
        `<12|name`value>
        `{/page/partial.mu}
        """)

        let nestedBlockIndents = doc.elements.compactMap { element -> Int? in
            switch element {
            case .divider, .literalBlock, .formField, .partial:
                return element.sectionIndent
            case .heading, .paragraph:
                return nil
            }
        }
        XCTAssertEqual(nestedBlockIndents, [2, 2, 2, 2])
    }

    // MARK: - Dividers

    func testDefaultDivider() {
        let doc = MicronParser.parse("-")
        guard case .divider(let ch, _) = doc.elements.first else {
            XCTFail("Expected divider"); return
        }
        XCTAssertNil(ch)
    }

    func testCustomDivider() {
        let doc = MicronParser.parse("-=")
        guard case .divider(let ch, _) = doc.elements.first else {
            XCTFail("Expected divider"); return
        }
        XCTAssertEqual(ch, "=")
    }

    // MARK: - Comments

    func testCommentsAreSkipped() {
        let doc = MicronParser.parse("# This is a comment\nVisible")
        XCTAssertEqual(doc.elements.count, 1)
        guard case .paragraph(let spans, _, _) = doc.elements[0] else {
            XCTFail("Expected paragraph"); return
        }
        if case .text(let text, _) = spans[0] {
            XCTAssertEqual(text, "Visible")
        }
    }

    // MARK: - Literal Blocks

    func testLiteralBlock() {
        let doc = MicronParser.parse("`=\nfoo\nbar\n`=")
        guard case .literalBlock(let text, _) = doc.elements.first else {
            XCTFail("Expected literal block"); return
        }
        XCTAssertEqual(text, "foo\nbar")
    }

    func testUnclosedLiteralBlock() {
        let doc = MicronParser.parse("`=\nsome code")
        guard case .literalBlock(let text, _) = doc.elements.first else {
            XCTFail("Expected literal block"); return
        }
        XCTAssertEqual(text, "some code")
    }

    // MARK: - Inline Formatting

    func testBoldToggle() {
        let doc = MicronParser.parse("`!bold`! normal")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        XCTAssertEqual(spans.count, 2)
        if case .text(let t, let s) = spans[0] {
            XCTAssertEqual(t, "bold")
            XCTAssertTrue(s.bold)
        } else { XCTFail("Expected text") }
        if case .text(let t, let s) = spans[1] {
            XCTAssertEqual(t, " normal")
            XCTAssertFalse(s.bold)
        } else { XCTFail("Expected text") }
    }

    func testItalicToggle() {
        let doc = MicronParser.parse("`*italic`* plain")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        if case .text(_, let s) = spans[0] {
            XCTAssertTrue(s.italic)
        } else { XCTFail("Expected text") }
        if case .text(_, let s) = spans[1] {
            XCTAssertFalse(s.italic)
        } else { XCTFail("Expected text") }
    }

    func testUnderlineToggle() {
        let doc = MicronParser.parse("`_underlined`_ plain")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        if case .text(_, let s) = spans[0] {
            XCTAssertTrue(s.underline)
        } else { XCTFail("Expected text") }
    }

    func testDoubleBacktickReset() {
        let doc = MicronParser.parse("`!`*styled`` plain")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        XCTAssertEqual(spans.count, 2)
        if case .text(_, let s) = spans[0] {
            XCTAssertTrue(s.bold)
            XCTAssertTrue(s.italic)
        } else { XCTFail("Expected text") }
        if case .text(_, let s) = spans[1] {
            XCTAssertFalse(s.bold)
            XCTAssertFalse(s.italic)
        } else { XCTFail("Expected text") }
    }

    // MARK: - Cross-line Formatting State (issue #31)

    func testStylePersistsAcrossLines() {
        let doc = MicronParser.parse("`!bold-on-line-1\nplain-on-line-2")
        XCTAssertEqual(doc.elements.count, 2)
        guard case .paragraph(let line1Spans, _, _) = doc.elements[0] else {
            XCTFail("Expected paragraph at 0"); return
        }
        XCTAssertEqual(line1Spans.count, 1)
        guard case .text(let t1, let s1) = line1Spans[0] else {
            XCTFail("Expected text on line 1"); return
        }
        XCTAssertEqual(t1, "bold-on-line-1")
        XCTAssertTrue(s1.bold)

        guard case .paragraph(let line2Spans, _, _) = doc.elements[1] else {
            XCTFail("Expected paragraph at 1"); return
        }
        XCTAssertEqual(line2Spans.count, 1)
        guard case .text(let t2, let s2) = line2Spans[0] else {
            XCTFail("Expected text on line 2"); return
        }
        XCTAssertEqual(t2, "plain-on-line-2")
        XCTAssertTrue(s2.bold) // bold from line 1 carries because never toggled off
    }

    func testColorPreambleAppliesToFollowingLine() {
        let doc = MicronParser.parse("`F0ff`B52f\nART")
        XCTAssertEqual(doc.elements.count, 2)
        guard case .paragraph(let preambleSpans, _, _) = doc.elements[0] else {
            XCTFail("Expected paragraph at 0"); return
        }
        XCTAssertEqual(preambleSpans.count, 0) // color codes consumed; no text

        guard case .paragraph(let artSpans, _, _) = doc.elements[1] else {
            XCTFail("Expected paragraph at 1"); return
        }
        XCTAssertEqual(artSpans.count, 1)
        guard case .text(let text, let style) = artSpans[0] else {
            XCTFail("Expected text on ART line"); return
        }
        XCTAssertEqual(text, "ART")
        XCTAssertEqual(style.foregroundColor, "0ff")
        XCTAssertEqual(style.backgroundColor, "52f")
    }

    func testResetSequenceClearsStyleAcrossLines() {
        let doc = MicronParser.parse("`Ff00colored\n`f\nplain")
        XCTAssertEqual(doc.elements.count, 3)

        guard case .paragraph(let line1Spans, _, _) = doc.elements[0] else {
            XCTFail("Expected paragraph at 0"); return
        }
        XCTAssertEqual(line1Spans.count, 1)
        if case .text(let t, let s) = line1Spans[0] {
            XCTAssertEqual(t, "colored")
            XCTAssertEqual(s.foregroundColor, "f00")
        } else { XCTFail("Expected text on line 1") }

        guard case .paragraph(let line2Spans, _, _) = doc.elements[1] else {
            XCTFail("Expected paragraph at 1"); return
        }
        XCTAssertEqual(line2Spans.count, 0) // bare `f consumes; no text spans

        guard case .paragraph(let line3Spans, _, _) = doc.elements[2] else {
            XCTFail("Expected paragraph at 2"); return
        }
        XCTAssertEqual(line3Spans.count, 1)
        if case .text(let t, let s) = line3Spans[0] {
            XCTAssertEqual(t, "plain")
            XCTAssertNil(s.foregroundColor) // reset on line 2 must persist to line 3
        } else { XCTFail("Expected text on line 3") }
    }

    func testDoubleBacktickResetPersists() {
        // `!`*styled`` carries no styles into the next line.
        let doc = MicronParser.parse("`!`*styled``\nplain")
        XCTAssertEqual(doc.elements.count, 2)

        guard case .paragraph(let line2Spans, _, _) = doc.elements[1] else {
            XCTFail("Expected paragraph at 1"); return
        }
        XCTAssertEqual(line2Spans.count, 1)
        guard case .text(let t, let s) = line2Spans[0] else {
            XCTFail("Expected text on line 2"); return
        }
        XCTAssertEqual(t, "plain")
        XCTAssertFalse(s.bold)
        XCTAssertFalse(s.italic)
        XCTAssertFalse(s.underline)
        XCTAssertNil(s.foregroundColor)
        XCTAssertNil(s.backgroundColor)
    }

    /// Regression sentinel for the chat-room page (issue #31). A trimmed but
    /// structurally representative chunk: `Faff prefix, then `F0ff`B52f
    /// preamble before the ASCII art, then `f`b reset.
    func testTheChatRoomFixture() {
        let markup = """
        `Faff Welcome To:

        `F0ff`B52f
        ART
        `f`b
        """
        let doc = MicronParser.parse(markup)
        XCTAssertEqual(doc.elements.count, 5)

        // Line 0: `Faff Welcome To: → fg=aff
        guard case .paragraph(let welcomeSpans, _, _) = doc.elements[0] else {
            XCTFail("Expected paragraph at 0"); return
        }
        XCTAssertEqual(welcomeSpans.count, 1)
        if case .text(let t, let s) = welcomeSpans[0] {
            XCTAssertEqual(t, " Welcome To:")
            XCTAssertEqual(s.foregroundColor, "aff")
            XCTAssertNil(s.backgroundColor)
        } else { XCTFail("Expected text") }

        // Line 1: blank line → empty paragraph
        guard case .paragraph(let blankSpans, _, _) = doc.elements[1] else {
            XCTFail("Expected paragraph at 1"); return
        }
        XCTAssertEqual(blankSpans.count, 1)
        if case .text(let t, _) = blankSpans[0] {
            XCTAssertEqual(t, "")
        } else { XCTFail("Expected empty text") }

        // Line 2: `F0ff`B52f preamble → no text spans
        guard case .paragraph(let preambleSpans, _, _) = doc.elements[2] else {
            XCTFail("Expected paragraph at 2"); return
        }
        XCTAssertEqual(preambleSpans.count, 0)

        // Line 3: ART must carry fg=0ff, bg=52f from the preamble
        guard case .paragraph(let artSpans, _, _) = doc.elements[3] else {
            XCTFail("Expected paragraph at 3"); return
        }
        XCTAssertEqual(artSpans.count, 1)
        if case .text(let t, let s) = artSpans[0] {
            XCTAssertEqual(t, "ART")
            XCTAssertEqual(s.foregroundColor, "0ff")
            XCTAssertEqual(s.backgroundColor, "52f")
        } else { XCTFail("Expected text") }

        // Line 4: `f`b reset → no text spans
        guard case .paragraph(let resetSpans, _, _) = doc.elements[4] else {
            XCTFail("Expected paragraph at 4"); return
        }
        XCTAssertEqual(resetSpans.count, 0)
    }

    func testSectionResetPreservesFormattingState() {
        // Canonical NomadNet uses `<` only to reset section depth. Formatting
        // remains document-scoped until its own reset command is encountered.
        let doc = MicronParser.parse("`!bold-line\n<plain-after-reset")
        XCTAssertEqual(doc.elements.count, 2)

        guard case .paragraph(let line2Spans, _, _) = doc.elements[1] else {
            XCTFail("Expected paragraph at 1"); return
        }
        XCTAssertEqual(line2Spans.count, 1)
        if case .text(let t, let s) = line2Spans[0] {
            XCTAssertEqual(t, "plain-after-reset")
            XCTAssertTrue(s.bold)
        } else { XCTFail("Expected text") }
    }

    // MARK: - Colors

    func testForegroundColor() {
        let doc = MicronParser.parse("`Ff00red`f normal")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        if case .text(let t, let s) = spans[0] {
            XCTAssertEqual(t, "red")
            XCTAssertEqual(s.foregroundColor, "f00")
        } else { XCTFail("Expected text") }
        if case .text(_, let s) = spans[1] {
            XCTAssertNil(s.foregroundColor)
        } else { XCTFail("Expected text") }
    }

    func testBackgroundColor() {
        let doc = MicronParser.parse("`B00fblue`b normal")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        if case .text(let t, let s) = spans[0] {
            XCTAssertEqual(t, "blue")
            XCTAssertEqual(s.backgroundColor, "00f")
        } else { XCTFail("Expected text") }
    }

    func testRngitTrueColorsRenderWithoutLeakingControlPayloads() {
        let markup = """
        `BT282828`Fddd`FT8b949e# Add tasks`f
        `FTc9d1d9nt add `FTa5d6ff"Buy groceries"`f`b
        """

        let doc = MicronParser.parse(markup)
        let renderedText = doc.elements.compactMap { element -> String? in
            guard case .paragraph(let spans, _, _) = element else { return nil }
            return spans.compactMap { span -> String? in
                guard case .text(let text, _) = span else { return nil }
                return text
            }.joined()
        }.joined(separator: "\n")

        XCTAssertEqual(renderedText, "# Add tasks\nnt add \"Buy groceries\"")

        guard case .paragraph(let commentSpans, _, _) = doc.elements[0],
              case .text(_, let commentStyle) = commentSpans.first,
              case .paragraph(let commandSpans, _, _) = doc.elements[1],
              case .text(_, let commandStyle) = commandSpans[0],
              case .text(_, let argumentStyle) = commandSpans[1] else {
            XCTFail("Expected rngit true-color text spans")
            return
        }

        XCTAssertEqual(commentStyle.foregroundColor, "8b949e")
        XCTAssertEqual(commentStyle.backgroundColor, "282828")
        XCTAssertEqual(commandStyle.foregroundColor, "c9d1d9")
        XCTAssertEqual(commandStyle.backgroundColor, "282828")
        XCTAssertEqual(argumentStyle.foregroundColor, "a5d6ff")
        XCTAssertEqual(argumentStyle.backgroundColor, "282828")
    }

    func testMalformedAndTruncatedTrueColorsDoNotChangeStyle() {
        let foreground = MicronParser.parse("`FT12")
        let background = MicronParser.parse("`BT12")
        let malformedForeground = MicronParser.parse("`FTzzzzzztext")
        let malformedBackground = MicronParser.parse("`BTggggggtext")

        let foregroundText = singleText(from: foreground)
        let backgroundText = singleText(from: background)
        let malformedForegroundText = singleText(from: malformedForeground)
        let malformedBackgroundText = singleText(from: malformedBackground)

        XCTAssertEqual(foregroundText.0, "T12")
        XCTAssertEqual(foregroundText.1, .plain)
        XCTAssertEqual(backgroundText.0, "T12")
        XCTAssertEqual(backgroundText.1, .plain)
        XCTAssertEqual(malformedForegroundText.0, "Tzzzzzztext")
        XCTAssertEqual(malformedForegroundText.1, .plain)
        XCTAssertEqual(malformedBackgroundText.0, "Tggggggtext")
        XCTAssertEqual(malformedBackgroundText.1, .plain)
    }

    #if canImport(UIKit)
    func testTrueColorConvertsToExactRGBComponents() throws {
        let color = try XCTUnwrap(MicronTextStyle.colorFromStyleHex("8b949e"))
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 0x8b / 255.0, accuracy: 0.001)
        XCTAssertEqual(green, 0x94 / 255.0, accuracy: 0.001)
        XCTAssertEqual(blue, 0x9e / 255.0, accuracy: 0.001)
        XCTAssertEqual(alpha, 1, accuracy: 0.001)
    }

    func testPageHeaderColorRemainsLegacyThreeDigitOnly() {
        XCTAssertNotNil(MicronTextStyle.colorFrom3Hex("abc"))
        XCTAssertNil(MicronTextStyle.colorFrom3Hex("aabbcc"))
    }

    @MainActor
    func testRngitTrueColorsReachMonospaceRenderer() throws {
        let document = MicronParser.parse("`BT282828`FT8b949e# Add tasks")
        guard case .paragraph(let spans, _, _) = document.elements.first else {
            XCTFail("Expected rngit paragraph")
            return
        }

        let size = CGSize(width: 320, height: 160)
        let host = UIHostingController(
            rootView: MonospaceLineView(
                spans: spans,
                fontSize: 18,
                cellHeight: 32,
                alignment: .left,
                bold: false
            )
            .frame(width: 300, height: 32, alignment: .leading)
            .padding(10)
            .frame(width: size.width, height: size.height, alignment: .center)
            .background(Color.white)
            .ignoresSafeArea()
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }

        XCTAssertGreaterThan(pixelCount(in: image, near: (0x28, 0x28, 0x28), tolerance: 8), 100)
        XCTAssertGreaterThan(pixelCount(in: image, near: (0x8b, 0x94, 0x9e), tolerance: 12), 5)

        let attachment = XCTAttachment(image: image)
        attachment.name = "nomadnet-rngit-true-color-line"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCanonicalDarkSectionHeadingsRenderPaletteBackgrounds() {
        let document = MicronParser.parse("""
        <>The Non-linear Task Manager
        >>`[Key Features`:/page/features.mu]
        >>>Installation
        """)
        let size = CGSize(width: 340, height: 360)
        let host = UIHostingController(
            rootView: MicronDocumentView(
                document: document,
                formFields: .constant([:]),
                checkboxFields: .constant([:]),
                radioFields: .constant([:]),
                style: .proportional,
                viewportWidth: 320
            )
            .frame(width: 320, alignment: .leading)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .padding(10)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.black)
            .ignoresSafeArea()
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }

        // Canonical NomadNet dark heading backgrounds: level 1 = bbb,
        // level 2 = 999, level 3 (and deeper) = 777.
        XCTAssertGreaterThan(pixelCount(in: image, near: (0xbb, 0xbb, 0xbb), tolerance: 4), 500)
        XCTAssertGreaterThan(pixelCount(in: image, near: (0x99, 0x99, 0x99), tolerance: 4), 500)
        XCTAssertGreaterThan(pixelCount(in: image, near: (0x77, 0x77, 0x77), tolerance: 4), 500)
        XCTAssertLessThan(blueDominantPixelCount(in: image), 5)

        let level1Background = dominantBandBounds(in: image, near: (0xbb, 0xbb, 0xbb), tolerance: 4)
        let level2Background = dominantBandBounds(in: image, near: (0x99, 0x99, 0x99), tolerance: 4)
        let level3Background = dominantBandBounds(in: image, near: (0x77, 0x77, 0x77), tolerance: 4)
        XCTAssertNotNil(level1Background)
        XCTAssertNotNil(level2Background)
        XCTAssertNotNil(level3Background)
        if let level1Background, let level2Background, let level3Background {
            XCTAssertEqual(level1Background.minX, level2Background.minX, accuracy: 4)
            XCTAssertEqual(level2Background.minX, level3Background.minX, accuracy: 4)
            XCTAssertEqual(level1Background.maxX, level2Background.maxX, accuracy: 4)
            XCTAssertEqual(level2Background.maxX, level3Background.maxX, accuracy: 4)

            let level1Text = pixelBounds(
                in: image,
                near: (0x22, 0x22, 0x22),
                tolerance: 8,
                inside: level1Background
            )
            let level2Text = pixelBounds(
                in: image,
                near: (0x11, 0x11, 0x11),
                tolerance: 8,
                inside: level2Background
            )
            let level3Text = pixelBounds(
                in: image,
                near: (0x00, 0x00, 0x00),
                tolerance: 4,
                inside: level3Background.insetBy(dx: 30, dy: 4)
            )
            XCTAssertNotNil(level1Text)
            XCTAssertNotNil(level2Text)
            XCTAssertNotNil(level3Text)
            if let level1Text, let level2Text, let level3Text {
                XCTAssertGreaterThan((level2Text.minX - level1Text.minX) / image.scale, 10)
                XCTAssertGreaterThan((level3Text.minX - level2Text.minX) / image.scale, 10)
                XCTAssertGreaterThanOrEqual(level1Text.minY, level1Background.minY)
                XCTAssertLessThanOrEqual(level1Text.maxY, level1Background.maxY)
                XCTAssertGreaterThanOrEqual(level2Text.minY, level2Background.minY)
                XCTAssertLessThanOrEqual(level2Text.maxY, level2Background.maxY)
                XCTAssertGreaterThanOrEqual(level3Text.minY, level3Background.minY)
                XCTAssertLessThanOrEqual(level3Text.maxY, level3Background.maxY)
            }
        }

        let attachment = XCTAttachment(image: image)
        attachment.name = "nomadnet-canonical-dark-section-headings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testMonospaceHeadingLinkInheritsCanonicalForeground() {
        let document = MicronParser.parse(">>`[Key Features`:/page/features.mu]")
        let size = CGSize(width: 340, height: 100)
        let host = UIHostingController(
            rootView: MicronDocumentView(
                document: document,
                formFields: .constant([:]),
                checkboxFields: .constant([:]),
                radioFields: .constant([:]),
                style: .monospaceScroll,
                viewportWidth: 320
            )
            .frame(width: 320, alignment: .leading)
            .environment(\.colorScheme, .dark)
            .padding(10)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.black)
            .ignoresSafeArea()
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }

        XCTAssertGreaterThan(pixelCount(in: image, near: (0x99, 0x99, 0x99), tolerance: 4), 500)
        XCTAssertGreaterThan(pixelCount(in: image, near: (0x11, 0x11, 0x11), tolerance: 8), 5)
        XCTAssertLessThan(blueDominantPixelCount(in: image), 5)

        let attachment = XCTAttachment(image: image)
        attachment.name = "nomadnet-monospace-heading-link"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLightPartialHeadingUsesCanonicalPalette() {
        let partial = MicronPartial(
            url: "/page/partial.mu",
            refreshInterval: nil,
            partialId: nil,
            fieldNames: nil
        )
        let document = MicronDocument(elements: [.partial(partial, indentLevel: 0)])
        let partialDocument = MicronParser.parse(">>`[Partial Heading`:/page/target.mu]")
        let size = CGSize(width: 340, height: 120)
        let host = UIHostingController(
            rootView: MicronDocumentView(
                document: document,
                formFields: .constant([:]),
                checkboxFields: .constant([:]),
                radioFields: .constant([:]),
                partialDocuments: [partial.url: partialDocument],
                style: .proportional,
                viewportWidth: 320
            )
            .frame(width: 320, alignment: .leading)
            .environment(\.colorScheme, .light)
            .padding(10)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
            .ignoresSafeArea()
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }

        XCTAssertGreaterThan(pixelCount(in: image, near: (0xaa, 0xaa, 0xaa), tolerance: 4), 500)
        XCTAssertGreaterThan(pixelCount(in: image, near: (0x11, 0x11, 0x11), tolerance: 8), 5)
        XCTAssertLessThan(blueDominantPixelCount(in: image), 5)
    }

    @MainActor
    func testNestedWrappedParagraphReservesBothSectionMargins() {
        let content = "`Bf00" + String(repeating: "M ", count: 80)
        let document = MicronParser.parse(">>Nested\n\(content)")
        let size = CGSize(width: 340, height: 220)
        let host = UIHostingController(
            rootView: MicronDocumentView(
                document: document,
                formFields: .constant([:]),
                checkboxFields: .constant([:]),
                radioFields: .constant([:]),
                style: .proportional,
                viewportWidth: 320
            )
            .frame(width: 320, alignment: .leading)
            .environment(\.colorScheme, .light)
            .padding(10)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
            .ignoresSafeArea()
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }

        let bounds = pixelBounds(in: image, near: (0xff, 0x00, 0x00), tolerance: 4)
        XCTAssertNotNil(bounds)
        if let bounds {
            XCTAssertGreaterThan(bounds.minX / image.scale, 30)
            XCTAssertGreaterThan(
                (CGFloat(image.cgImage?.width ?? 0) - bounds.maxX) / image.scale,
                30
            )
        }
    }

    @MainActor
    func testZeroViewportScrollDividerKeepsIntrinsicFallbackWidth() {
        let document = MicronDocument(elements: [.divider(character: "=", indentLevel: 2)])
        let size = CGSize(width: 340, height: 80)
        let host = UIHostingController(
            rootView: MicronDocumentView(
                document: document,
                formFields: .constant([:]),
                checkboxFields: .constant([:]),
                radioFields: .constant([:]),
                style: .monospaceScroll
            )
            .frame(width: 320, alignment: .leading)
            .environment(\.colorScheme, .light)
            .padding(10)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
            .ignoresSafeArea()
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }

        let bounds = pixelBounds(in: image, near: (0x00, 0x00, 0x00), tolerance: 24)
        XCTAssertNotNil(bounds)
        if let bounds {
            XCTAssertGreaterThan(bounds.width / image.scale, 200)
            XCTAssertGreaterThan(bounds.minX / image.scale, 20)
        }
    }

    @MainActor
    func testLoadedPartialRecursivelyRendersFormsAndNestedPartialsInEveryMode() {
        let outer = MicronPartial(url: "/outer.mu", refreshInterval: nil, partialId: nil, fieldNames: nil)
        let inner = MicronPartial(url: "/inner.mu", refreshInterval: nil, partialId: nil, fieldNames: nil)
        let rootDocument = MicronDocument(elements: [.partial(outer, indentLevel: 0)])
        let outerDocument = MicronDocument(elements: [
            .formField(.textInput(width: 12, name: "nested", defaultValue: "value"), indentLevel: 2),
            .partial(inner, indentLevel: 2),
        ])
        let innerDocument = MicronParser.parse(">>Nested Partial")
        let partials = [outer.url: outerDocument, inner.url: innerDocument]
        let styles: [MicronRenderStyle] = [.monospaceScroll, .monospaceCompact, .proportional]

        for style in styles {
            let size = CGSize(width: 340, height: 180)
            let host = UIHostingController(
                rootView: MicronDocumentView(
                    document: rootDocument,
                    formFields: .constant([:]),
                    checkboxFields: .constant([:]),
                    radioFields: .constant([:]),
                    partialDocuments: partials,
                    style: style,
                    viewportWidth: 320
                )
                .frame(width: 320, alignment: .leading)
                .environment(\.colorScheme, .light)
                .padding(10)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.white)
                .ignoresSafeArea()
            )
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.layoutIfNeeded()

            XCTAssertEqual(descendants(of: host.view, matching: UITextField.self).count, 1, "style: \(style)")
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(
                pixelCount(in: image, near: (0xaa, 0xaa, 0xaa), tolerance: 4),
                100,
                "style: \(style)"
            )
            window.isHidden = true
        }
    }

    private func descendants<T: UIView>(of root: UIView, matching type: T.Type) -> [T] {
        root.subviews.flatMap { child in
            var matches = (child as? T).map { [$0] } ?? []
            matches.append(contentsOf: descendants(of: child, matching: type))
            return matches
        }
    }

    private func pixelCount(
        in image: UIImage,
        near expected: (UInt8, UInt8, UInt8),
        tolerance: Int
    ) -> Int {
        guard let source = image.cgImage else { return 0 }
        let width = source.width
        let height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            if abs(red - Int(expected.0)) <= tolerance,
               abs(green - Int(expected.1)) <= tolerance,
               abs(blue - Int(expected.2)) <= tolerance {
                count += 1
            }
        }
    }

    private func blueDominantPixelCount(in image: UIImage) -> Int {
        guard let source = image.cgImage else { return 0 }
        let width = source.width
        let height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            if blue > red + 50, blue > green + 50 {
                count += 1
            }
        }
    }

    private func dominantBandBounds(
        in image: UIImage,
        near expected: (UInt8, UInt8, UInt8),
        tolerance: Int
    ) -> CGRect? {
        guard let source = image.cgImage else { return nil }
        let width = source.width
        let height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        func matches(_ index: Int) -> Bool {
            abs(Int(pixels[index]) - Int(expected.0)) <= tolerance
                && abs(Int(pixels[index + 1]) - Int(expected.1)) <= tolerance
                && abs(Int(pixels[index + 2]) - Int(expected.2)) <= tolerance
        }

        let dominantRows = (0..<height).filter { y in
            (0..<width).reduce(into: 0) { count, x in
                if matches((y * width + x) * 4) { count += 1 }
            } > width / 2
        }
        guard let minY = dominantRows.first, let maxY = dominantRows.last else { return nil }

        var minX = width
        var maxX = -1
        for y in dominantRows {
            for x in 0..<width where matches((y * width + x) * 4) {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func pixelBounds(
        in image: UIImage,
        near expected: (UInt8, UInt8, UInt8),
        tolerance: Int,
        inside region: CGRect? = nil
    ) -> CGRect? {
        guard let source = image.cgImage else { return nil }
        let width = source.width
        let height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let search = region?.integral.intersection(canvas) ?? canvas
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in Int(search.minY)..<Int(search.maxY) {
            for x in Int(search.minX)..<Int(search.maxX) {
                let index = (y * width + x) * 4
                let red = Int(pixels[index])
                let green = Int(pixels[index + 1])
                let blue = Int(pixels[index + 2])
                if abs(red - Int(expected.0)) <= tolerance,
                   abs(green - Int(expected.1)) <= tolerance,
                   abs(blue - Int(expected.2)) <= tolerance {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    #endif

    private func singleText(from document: MicronDocument) -> (String, MicronTextStyle) {
        guard case .paragraph(let spans, _, _) = document.elements.first,
              case .text(let text, let style) = spans.first else {
            XCTFail("Expected one text span")
            return ("", .plain)
        }
        return (text, style)
    }

    // MARK: - Alignment

    func testCenterAlignment() {
        let doc = MicronParser.parse("`cCentered text")
        guard case .paragraph(_, let alignment, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        XCTAssertEqual(alignment, .center)
    }

    func testRightAlignment() {
        let doc = MicronParser.parse("`rRight aligned")
        guard case .paragraph(_, let alignment, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        XCTAssertEqual(alignment, .right)
    }

    // MARK: - Links

    func testSimpleLink() {
        let doc = MicronParser.parse("`[About`/page/about.mu]")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        guard case .link(let link) = spans.first else {
            XCTFail("Expected link"); return
        }
        XCTAssertEqual(link.label, "About")
        XCTAssertEqual(link.url, .samePage(path: "/page/about.mu"))
    }

    func testRemoteNodeLink() {
        let doc = MicronParser.parse("`[Remote`a1b2c3d4e5f67890:/page/index.mu]")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        guard case .link(let link) = spans.first else {
            XCTFail("Expected link"); return
        }
        XCTAssertEqual(link.label, "Remote")
        XCTAssertEqual(link.url, .remoteNode(hash: "a1b2c3d4e5f67890", path: "/page/index.mu"))
    }

    func testLxmfLink() {
        let doc = MicronParser.parse("`[Message Me`lxmf@abc123def456]")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        guard case .link(let link) = spans.first else {
            XCTFail("Expected link"); return
        }
        XCTAssertEqual(link.url, .lxmf(hash: "abc123def456"))
    }

    func testLinkWithFields() {
        let doc = MicronParser.parse("`[Submit`/page/form.mu`username|password]")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        guard case .link(let link) = spans.first else {
            XCTFail("Expected link"); return
        }
        XCTAssertEqual(link.fieldNames, ["username", "password"])
    }

    func testRngitGroupLinkPreservesInlineVariable() {
        let doc = MicronParser.parse("`[reticulum`:/page/group.mu`g=reticulum]")
        guard case .paragraph(let spans, _, _) = doc.elements.first,
              case .link(let link) = spans.first else {
            XCTFail("Expected rngit group link")
            return
        }

        XCTAssertEqual(link.url, .samePage(path: "/page/group.mu"))
        XCTAssertEqual(link.fieldNames, ["g=reticulum"])
    }

    func testRngitInlineVariablesAndFormFieldsEncodeForNomadNetRequest() {
        let context = NomadNetRequestContext.build(
            fieldEntries: ["g=reticulum", "path=docs%2Fmanual", "query=hello+world", "username"],
            formFields: ["username": "torlando"],
            checkboxFields: [:],
            radioFields: [:]
        )

        XCTAssertEqual(context.requestData, [
            "var_g": "reticulum",
            "var_path": "docs%2Fmanual",
            "var_query": "hello+world",
            "field_username": "torlando",
        ])
        XCTAssertEqual(context.requestVariables, [
            "g": "reticulum",
            "path": "docs%2Fmanual",
            "query": "hello+world",
        ])
    }

    func testInlineMicronVariablesRemainByteForByteEquivalentStrings() {
        let context = NomadNetRequestContext.build(
            fieldEntries: [
                "plus=a+b",
                "encodedPlus=%2B",
                "percent=%25",
                "slash=%2F",
                "delimiter=%7C",
                "equals=%3D",
            ],
            formFields: [:],
            checkboxFields: [:],
            radioFields: [:]
        )

        XCTAssertEqual(context.requestData, [
            "var_plus": "a+b",
            "var_encodedPlus": "%2B",
            "var_percent": "%25",
            "var_slash": "%2F",
            "var_delimiter": "%7C",
            "var_equals": "%3D",
        ])
    }

    func testSubmitAllIncludesTextCheckboxAndRadioFields() {
        let context = NomadNetRequestContext.build(
            fieldEntries: ["*"],
            formFields: ["username": "torlando"],
            checkboxFields: ["features:mail": true, "features:voice": false],
            radioFields: ["theme": "dark"]
        )

        XCTAssertEqual(context.requestData, [
            "field_username": "torlando",
            "field_features": "mail",
            "field_theme": "dark",
        ])
        XCTAssertTrue(context.requestVariables.isEmpty)
    }

    func testNomadNetAddressPreservesSortedRequestVariables() {
        let location = NomadNetLocation(
            nodeHash: Data(repeating: 0xab, count: 16),
            path: "/page/group.mu",
            requestContext: NomadNetRequestContext(
                requestData: ["var_topic": "hello world", "var_g": "reticulum"],
                requestVariables: ["topic": "hello world", "g": "reticulum"]
            )
        )

        XCTAssertEqual(
            location.address,
            "abababababababababababababababab:/page/group.mu`g=reticulum|topic=hello+world"
        )
        XCTAssertEqual(
            location.shareableAddress,
            "nomadnetwork://abababababababababababababababab:/page/group.mu`g=reticulum|topic=hello+world"
        )

        let reopened = NomadNetLocation(
            nodeHash: location.nodeHash,
            addressPath: "/page/group.mu`g=reticulum|topic=hello+world"
        )
        XCTAssertEqual(reopened, location)
    }

    func testNomadNetAddressRoundTripsReservedVariableCharacters() {
        let variables = [
            "delimiter": "a|b",
            "equals": "a=b",
            "plus": "a+b",
            "percent": "a%b",
            "slash": "a/b",
        ]
        let location = NomadNetLocation(
            nodeHash: Data(repeating: 0xcd, count: 16),
            path: "/page/repo.mu",
            requestContext: NomadNetRequestContext(
                requestData: Dictionary(uniqueKeysWithValues: variables.map { ("var_\($0.key)", $0.value) }),
                requestVariables: variables
            )
        )

        XCTAssertEqual(
            location.address,
            "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd:/page/repo.mu`delimiter=a%7Cb|equals=a%3Db|percent=a%25b|plus=a%2Bb|slash=a%2Fb"
        )
        let addressPath = String(location.address.dropFirst(33))
        XCTAssertEqual(
            NomadNetLocation(nodeHash: location.nodeHash, addressPath: addressPath),
            location
        )
    }

    @MainActor
    func testRngitNavigationRefreshBackAndReopenSendExactVariablesWithoutSharingPassword() async throws {
        let backend = RecordingNomadNetBackend()
        let service = NomadNetBrowserService(backend: backend)
        let hash = Data(repeating: 0xef, count: 16)
        let viewModel = NomadNetBrowserViewModel(
            nodeHash: hash,
            nodeName: "rngit",
            initialPath: "/page/index.mu",
            browserService: service
        )
        viewModel.formFields["password"] = "never-share-this"

        await viewModel.handleLinkTap(MicronLink(
            label: "reticulum",
            url: .samePage(path: "/page/group.mu"),
            fieldNames: ["g=reticulum", "password"]
        ))
        var requests = await backend.requests()
        XCTAssertEqual(requests.last?.requestData, [
            "var_g": "reticulum",
            "field_password": "never-share-this",
        ])
        XCTAssertEqual(
            viewModel.shareableAddress,
            "nomadnetwork://efefefefefefefefefefefefefefefef:/page/group.mu`g=reticulum"
        )
        XCTAssertFalse(viewModel.shareableAddress.contains("never-share-this"))

        await viewModel.refresh()
        requests = await backend.requests()
        XCTAssertEqual(requests.last?.requestData?["var_g"], "reticulum")

        await viewModel.navigateTo(url: MicronURL.samePage(path: "/page/index.mu"))
        await viewModel.goBack()
        await viewModel.refresh()
        requests = await backend.requests()
        XCTAssertEqual(requests.last?.path, "/page/group.mu")
        XCTAssertEqual(requests.last?.requestData?["var_g"], "reticulum")

        let reopened = NomadNetBrowserViewModel(
            nodeHash: hash,
            nodeName: nil,
            initialPath: "/page/repo.mu`g=reticulum|r=lxmf|path=docs%252Fmanual",
            browserService: service
        )
        await reopened.loadPage()
        requests = await backend.requests()
        XCTAssertEqual(requests.last?.path, "/page/repo.mu")
        XCTAssertEqual(requests.last?.requestData, [
            "var_g": "reticulum",
            "var_r": "lxmf",
            "var_path": "docs%2Fmanual",
        ])
    }

    func testLinkWithSurroundingText() {
        let doc = MicronParser.parse("Click `[here`/page/info.mu] for info")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        XCTAssertEqual(spans.count, 3)
        if case .text(let t, _) = spans[0] { XCTAssertEqual(t, "Click ") }
        if case .link(let l) = spans[1] { XCTAssertEqual(l.label, "here") }
        if case .text(let t, _) = spans[2] { XCTAssertEqual(t, " for info") }
    }

    // MARK: - Indent / Reset

    func testIndentResetWithContent() {
        let doc = MicronParser.parse(">>Section\n<Back to root")
        XCTAssertEqual(doc.elements.count, 2)
        guard case .paragraph(_, _, let indent) = doc.elements[1] else {
            XCTFail("Expected paragraph"); return
        }
        XCTAssertEqual(indent, 0)
    }

    // MARK: - Escaped Lines

    func testEscapedLine() {
        let doc = MicronParser.parse("\\>Not a heading")
        guard case .paragraph(let spans, _, _) = doc.elements.first else {
            XCTFail("Expected paragraph"); return
        }
        if case .text(let t, _) = spans[0] {
            XCTAssertEqual(t, ">Not a heading")
        }
    }

    // MARK: - Empty Document

    func testEmptyDocument() {
        let doc = MicronParser.parse("")
        XCTAssertEqual(doc.elements.count, 1) // one empty paragraph from the empty line
    }

    // MARK: - URL Parsing

    func testURLParsingSamePage() {
        XCTAssertEqual(MicronParser.parseURL("/page/about.mu"), .samePage(path: "/page/about.mu"))
    }

    func testURLParsingColonPrefix() {
        XCTAssertEqual(MicronParser.parseURL(":/page/about.mu"), .samePage(path: "/page/about.mu"))
    }

    func testURLParsingRemoteNode() {
        XCTAssertEqual(
            MicronParser.parseURL("abcdef1234567890:/page/index.mu"),
            .remoteNode(hash: "abcdef1234567890", path: "/page/index.mu")
        )
    }

    func testURLParsingBareHash() {
        let url = MicronParser.parseURL("abcdef1234567890abcdef1234567890")
        XCTAssertEqual(url, .remoteNode(hash: "abcdef1234567890abcdef1234567890", path: "/page/index.mu"))
    }

    func testURLParsingLxmf() {
        XCTAssertEqual(MicronParser.parseURL("lxmf@abc123"), .lxmf(hash: "abc123"))
    }

    // MARK: - Form Fields

    func testTextInput() {
        let doc = MicronParser.parse("`<24|username`admin>")
        let formElements = doc.elements.filter { if case .formField = $0 { return true }; return false }
        XCTAssertEqual(formElements.count, 1)
        guard case .formField(let field, _) = formElements[0] else { XCTFail("Expected form field"); return }
        guard case .textInput(let width, let name, let defaultValue) = field else {
            XCTFail("Expected text input"); return
        }
        XCTAssertEqual(width, 24)
        XCTAssertEqual(name, "username")
        XCTAssertEqual(defaultValue, "admin")
    }

    func testPasswordInput() {
        let doc = MicronParser.parse("`<!|password`>")
        let formElements = doc.elements.filter { if case .formField = $0 { return true }; return false }
        XCTAssertEqual(formElements.count, 1)
        guard case .formField(let field, _) = formElements[0] else { XCTFail("Expected form field"); return }
        guard case .passwordInput(let name, _) = field else {
            XCTFail("Expected password input"); return
        }
        XCTAssertEqual(name, "password")
    }

    func testCheckbox() {
        let doc = MicronParser.parse("`<?|option|yes`>Accept terms")
        let formElements = doc.elements.filter { if case .formField = $0 { return true }; return false }
        XCTAssertEqual(formElements.count, 1)
        guard case .formField(let field, _) = formElements[0] else { XCTFail("Expected form field"); return }
        guard case .checkbox(let name, let value, let label, let checked) = field else {
            XCTFail("Expected checkbox"); return
        }
        XCTAssertEqual(name, "option")
        XCTAssertEqual(value, "yes")
        XCTAssertTrue(label.contains("Accept terms"))
        XCTAssertFalse(checked)
    }

    func testCheckboxPrechecked() {
        let doc = MicronParser.parse("`<?|option|yes|*`>Accept terms")
        let formElements = doc.elements.filter { if case .formField = $0 { return true }; return false }
        guard case .formField(let field, _) = formElements[0] else { XCTFail("Expected form field"); return }
        guard case .checkbox(_, _, _, let checked) = field else {
            XCTFail("Expected checkbox"); return
        }
        XCTAssertTrue(checked)
    }

    func testRadioButton() {
        let doc = MicronParser.parse("`<^|choice|a`>Option A")
        let formElements = doc.elements.filter { if case .formField = $0 { return true }; return false }
        XCTAssertEqual(formElements.count, 1)
        guard case .formField(let field, _) = formElements[0] else { XCTFail("Expected form field"); return }
        guard case .radio(let name, let value, let label, let selected) = field else {
            XCTFail("Expected radio"); return
        }
        XCTAssertEqual(name, "choice")
        XCTAssertEqual(value, "a")
        XCTAssertTrue(label.contains("Option A"))
        XCTAssertFalse(selected)
    }

    func testRadioPreselected() {
        let doc = MicronParser.parse("`<^|choice|b|*`>Option B")
        let formElements = doc.elements.filter { if case .formField = $0 { return true }; return false }
        guard case .formField(let field, _) = formElements[0] else { XCTFail("Expected form field"); return }
        guard case .radio(_, _, _, let selected) = field else {
            XCTFail("Expected radio"); return
        }
        XCTAssertTrue(selected)
    }

    // MARK: - Partials

    func testSimplePartial() {
        let doc = MicronParser.parse("`{/page/status.mu}")
        let partials = doc.elements.filter { if case .partial = $0 { return true }; return false }
        XCTAssertEqual(partials.count, 1)
        guard case .partial(let p, _) = partials[0] else { XCTFail("Expected partial"); return }
        XCTAssertEqual(p.url, "/page/status.mu")
        XCTAssertNil(p.refreshInterval)
        XCTAssertNil(p.partialId)
    }

    func testPartialWithRefresh() {
        let doc = MicronParser.parse("`{/page/status.mu`5}")
        guard case .partial(let p, _) = doc.elements.first(where: { if case .partial = $0 { return true }; return false }) else {
            XCTFail("Expected partial"); return
        }
        XCTAssertEqual(p.url, "/page/status.mu")
        XCTAssertEqual(p.refreshInterval, 5)
    }

    func testPartialWithIdAndFields() {
        let doc = MicronParser.parse("`{/page/widget.mu`10`pid=status|username}")
        guard case .partial(let p, _) = doc.elements.first(where: { if case .partial = $0 { return true }; return false }) else {
            XCTFail("Expected partial"); return
        }
        XCTAssertEqual(p.url, "/page/widget.mu")
        XCTAssertEqual(p.refreshInterval, 10)
        XCTAssertEqual(p.partialId, "status")
        XCTAssertEqual(p.fieldNames, ["username"])
    }

    // MARK: - Mixed Content

    func testMixedDocument() {
        let markup = """
        #!c=120
        #!bg=111
        >Welcome
        -
        This is `!bold`! and `*italic`*.
        `[Click here`/page/about.mu]
        `=
        code block
        `=
        """
        let doc = MicronParser.parse(markup)
        XCTAssertEqual(doc.headers.cacheSeconds, 120)
        XCTAssertEqual(doc.headers.backgroundColor, "111")
        // heading, divider, paragraph with formatting, paragraph with link, literal block
        XCTAssert(doc.elements.count >= 4)
    }
}

// MARK: - MessageRepository adapter (Track A0)

/// Verifies the pure `static` mapping funcs in `MessageRepository` that adapt
/// the GRDB-backed `LXMFSwift` records to the RNSAPI Compat types the UI/
/// ViewModels consume. Exercises the load-bearing conversions called out in
/// A0: Date<-Double, RNSAPI-enum<-LXMFSwift-UInt8, String<-String?.
final class MessageRepositoryAdapterTests: XCTestCase {

    // MARK: Conversation list behavior

    func testConversationListSortsMostRecentActivityFirst() {
        let older = RNSAPI.ConversationRecord(
            hash: Data([0x01]),
            displayName: "Older",
            lastMessageAt: Date(timeIntervalSince1970: 100),
            lastMessage: "older message",
            unreadCount: 0
        )
        let newer = RNSAPI.ConversationRecord(
            hash: Data([0x02]),
            displayName: "Newer",
            lastMessageAt: Date(timeIntervalSince1970: 200),
            lastMessage: "newer message",
            unreadCount: 0
        )

        let sameTimestampLowerID = RNSAPI.ConversationRecord(
            hash: Data([0x00]),
            displayName: "Same timestamp",
            lastMessageAt: Date(timeIntervalSince1970: 200),
            lastMessage: "same timestamp message",
            unreadCount: 0
        )

        let conversations = ChatsViewModel.prepareConversations([older, newer, sameTimestampLowerID])

        XCTAssertEqual(
            conversations.map(\.destinationHash),
            [sameTimestampLowerID.hash, newer.hash, older.hash]
        )
    }

    @MainActor
    func testOverlappingLoadsKeepOperationSpecificIndicatorsAccurate() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-chat-loading-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let viewModel = ChatsViewModel(
            repository: repository,
            notificationObserver: NotificationObserver()
        )

        _ = viewModel.beginLoadingConversations()
        _ = viewModel.beginLoadingConversations()
        _ = viewModel.beginRefreshingConversations()
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.isRefreshing)

        viewModel.endLoadingConversations()
        XCTAssertTrue(viewModel.isLoading, "one ordinary load is still active")
        XCTAssertTrue(viewModel.isRefreshing, "ordinary load completion must not clear refresh state")

        viewModel.endRefreshingConversations()
        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertTrue(viewModel.isLoading, "refresh completion must not clear ordinary loading state")

        viewModel.endLoadingConversations()
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testOutboundActivityRefreshesAndReordersChatList() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-chat-order-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let viewModel = ChatsViewModel(
            repository: repository,
            notificationObserver: NotificationObserver()
        )
        let olderHash = Data([0x01])
        let newerHash = Data([0x02])

        let olderMessage = RNSAPI.LXMessage(
            destinationHash: olderHash,
            sourceIdentity: nil,
            content: Data("older".utf8)
        )
        olderMessage.hash = Data([0xA1])
        olderMessage.timestamp = 100
        olderMessage.state = .sent
        olderMessage.method = .opportunistic
        try await repository.saveMessage(olderMessage)
        await viewModel.loadConversations()
        XCTAssertEqual(viewModel.conversations.first?.destinationHash, olderHash)

        let newerMessage = RNSAPI.LXMessage(
            destinationHash: newerHash,
            sourceIdentity: nil,
            content: Data("newer".utf8)
        )
        newerMessage.hash = Data([0xA2])
        newerMessage.timestamp = 200
        newerMessage.state = .sent
        newerMessage.method = .opportunistic
        try await repository.saveMessage(newerMessage)

        for _ in 0..<100 where viewModel.conversations.first?.destinationHash != newerHash {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.conversations.map(\.destinationHash), [newerHash, olderHash])
    }

    @MainActor
    func testAnnouncedDisplayNameRefreshesVisibleChatList() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-chat-announced-name-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let viewModel = ChatsViewModel(
            repository: repository,
            notificationObserver: NotificationObserver()
        )
        let destination = Data([0x05, 0xc5, 0x7e, 0x42] + Array(repeating: 0xaa, count: 12))
        let message = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("hello".utf8)
        )
        message.hash = Data(repeating: 0xbb, count: 32)
        message.timestamp = 100
        message.incoming = true
        message.sourceHash = destination
        message.state = .received
        message.method = .opportunistic
        try await repository.saveMessage(message)
        try await repository.ensureConversation(destination, displayName: "Peer 05c57e42")
        await viewModel.loadConversations()
        for _ in 0..<100 where viewModel.conversations.first?.displayName != "Peer 05c57e42" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.conversations.first?.displayName, "Peer 05c57e42")

        let applied = try await repository.applyAnnouncedDisplayName(
            destination,
            displayName: "Hermes Homelab"
        )
        XCTAssertTrue(applied)

        for _ in 0..<100 where viewModel.conversations.first?.displayName != "Hermes Homelab" {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.conversations.first?.displayName, "Hermes Homelab")
    }

    @MainActor
    func testConversationReadNotificationClearsVisibleUnreadBadge() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-chat-read-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let viewModel = ChatsViewModel(
            repository: repository,
            notificationObserver: NotificationObserver()
        )
        let hash = Data([0xAA, 0xBB])
        let staleConversation = Conversation(
            destinationHash: hash,
            displayName: "Peer",
            lastMessageTimestamp: Date(timeIntervalSince1970: 100),
            lastMessagePreview: "old message",
            unreadCount: 3
        )
        viewModel.conversations = [staleConversation]

        let incomingMessage = RNSAPI.LXMessage(
            destinationHash: Data([0xDD]),
            sourceIdentity: nil,
            content: Data("new message".utf8)
        )
        incomingMessage.sourceHash = hash
        incomingMessage.hash = Data([0xA3])
        incomingMessage.timestamp = 200
        incomingMessage.incoming = true
        incomingMessage.state = .received
        incomingMessage.method = .opportunistic
        try await repository.saveMessage(incomingMessage)
        try await repository.setUnreadCount(hash, count: 3)

        let staleGeneration = viewModel.beginConversationLoad()
        try await repository.markConversationRead(hash)

        for _ in 0..<100 where
            viewModel.conversations.first?.unreadCount != 0 ||
            viewModel.conversations.first?.lastMessagePreview != "new message" {
            try await Task.sleep(for: .milliseconds(10))
        }

        // Simulate a slower load attempting to apply the snapshot it captured
        // before markConversationRead completed. The read notification must have
        // invalidated that generation, while its replacement load must preserve
        // the new preview/timestamp and cleared unread state.
        viewModel.applyLoadedConversations([staleConversation], generation: staleGeneration)

        let persistedConversation = try await repository.fetchConversation(hash)
        XCTAssertEqual(viewModel.conversations.first?.unreadCount, 0)
        XCTAssertEqual(viewModel.conversations.first?.lastMessagePreview, "new message")
        XCTAssertEqual(viewModel.conversations.first?.lastMessageTimestamp, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(persistedConversation?.unreadCount, 0)
    }

    // MARK: Conversation mapping (Date<-Double, String<-String?)

    func testMapConversationFullFields() {
        var c = LXMFSwift.ConversationRecord(
            destinationHash: Data([0x01, 0x02, 0x03]),
            displayName: "Alice",
            lastMessageTimestamp: 1_700_000_000.5,
            lastMessagePreview: "hello",
            unreadCount: 3,
            isFavorite: true
        )
        c.isPinned = 1
        c.iconName = "account"
        c.iconFgColor = "ffffff"
        c.iconBgColor = "1e88e5"

        let r = MessageRepository.mapConversation(c)

        XCTAssertEqual(r.hash, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(r.displayName, "Alice")
        XCTAssertEqual(r.isFavorite, 1)
        XCTAssertEqual(r.isPinned, 1)
        // Date <- Double (timeIntervalSince1970)
        XCTAssertEqual(r.lastMessageAt, Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(r.lastMessage, "hello")
        XCTAssertEqual(r.unreadCount, 3)
        XCTAssertEqual(r.iconName, "account")
        XCTAssertEqual(r.iconFgColor, "ffffff")
        XCTAssertEqual(r.iconBgColor, "1e88e5")
    }

    func testMapConversationNilDisplayNameBecomesEmptyString() {
        // displayName is String? on the GRDB side, non-optional String on RNSAPI.
        let c = LXMFSwift.ConversationRecord(
            destinationHash: Data([0xAB]),
            displayName: nil,
            lastMessageTimestamp: 0,
            lastMessagePreview: nil,
            unreadCount: 0,
            isFavorite: false
        )
        let r = MessageRepository.mapConversation(c)
        XCTAssertEqual(r.displayName, "")            // String <- nil String?
        XCTAssertNil(r.lastMessage)                  // String? passes through
        XCTAssertEqual(r.isFavorite, 0)
        XCTAssertEqual(r.isPinned, 0)
        XCTAssertEqual(r.lastMessageAt, Date(timeIntervalSince1970: 0))
    }

    // MARK: State enum <- UInt8

    func testMapStateSemantic() {
        XCTAssertEqual(MessageRepository.mapState(LXMFSwift.LXMessageState.generating), .draft)
        XCTAssertEqual(MessageRepository.mapState(LXMFSwift.LXMessageState.outbound), .outbound)
        XCTAssertEqual(MessageRepository.mapState(LXMFSwift.LXMessageState.sending), .sending)
        XCTAssertEqual(MessageRepository.mapState(LXMFSwift.LXMessageState.sent), .sent)
        XCTAssertEqual(MessageRepository.mapState(LXMFSwift.LXMessageState.delivered), .delivered)
        XCTAssertEqual(MessageRepository.mapState(LXMFSwift.LXMessageState.rejected), .failed)
        XCTAssertEqual(MessageRepository.mapState(LXMFSwift.LXMessageState.cancelled), .failed)
        XCTAssertEqual(MessageRepository.mapState(LXMFSwift.LXMessageState.failed), .failed)
    }

    func testMapStateFromRawByte() {
        // 0x08 == delivered, 0xFF == failed, 0x01 == outbound
        XCTAssertEqual(MessageRepository.mapState(UInt8(0x08)), .delivered)
        XCTAssertEqual(MessageRepository.mapState(UInt8(0xFF)), .failed)
        XCTAssertEqual(MessageRepository.mapState(UInt8(0x01)), .outbound)
        // Unknown byte falls back to .sent (matches the chat UI default arm).
        XCTAssertEqual(MessageRepository.mapState(UInt8(0x77)), .sent)
    }

    func testMapStateToGRDBRoundTrip() {
        // received is inbound-only on RNSAPI; GRDB has no peer → delivered.
        XCTAssertEqual(MessageRepository.mapStateToGRDB(.received), .delivered)
        XCTAssertEqual(MessageRepository.mapStateToGRDB(.draft), .generating)
        for s: RNSAPI.LXMessageState in [.outbound, .sending, .sent, .delivered, .failed] {
            XCTAssertEqual(MessageRepository.mapState(MessageRepository.mapStateToGRDB(s)), s,
                           "round-trip should be stable for \(s)")
        }
    }

    // MARK: Method enum <- UInt8

    func testMapMethodSemantic() {
        XCTAssertEqual(MessageRepository.mapMethod(LXMFSwift.LXDeliveryMethod.opportunistic), .opportunistic)
        XCTAssertEqual(MessageRepository.mapMethod(LXMFSwift.LXDeliveryMethod.direct), .direct)
        XCTAssertEqual(MessageRepository.mapMethod(LXMFSwift.LXDeliveryMethod.propagated), .propagated)
        XCTAssertEqual(MessageRepository.mapMethod(LXMFSwift.LXDeliveryMethod.paper), .paper)
    }

    func testMapMethodFromRawByte() {
        XCTAssertEqual(MessageRepository.mapMethod(UInt8(0x01)), .opportunistic)
        XCTAssertEqual(MessageRepository.mapMethod(UInt8(0x02)), .direct)
        XCTAssertEqual(MessageRepository.mapMethod(UInt8(0x03)), .propagated)
        XCTAssertEqual(MessageRepository.mapMethod(UInt8(0x05)), .paper)
        // Unknown byte → .unknown
        XCTAssertEqual(MessageRepository.mapMethod(UInt8(0x42)), .unknown)
    }

    func testMapMethodToGRDBUnknownDefaultsOpportunistic() {
        XCTAssertEqual(MessageRepository.mapMethodToGRDB(.unknown), .opportunistic)
        for m: RNSAPI.LXDeliveryMethod in [.opportunistic, .direct, .propagated, .paper] {
            XCTAssertEqual(MessageRepository.mapMethod(MessageRepository.mapMethodToGRDB(m)), m,
                           "round-trip should be stable for \(m)")
        }
    }

    // MARK: MessageRecord mapping (all fields, incl. enum<-Int and String<-String?)

    /// Build a known GRDB `MessageRecord`. The struct's memberwise init is
    /// module-internal, and the only public init is `init(from: LXMessage)`,
    /// so seed it from a no-identity LXMFSwift.LXMessage (with `packed` set
    /// manually so the init's `guard packed != nil` passes), then set the
    /// columns that `init(from:)` doesn't take from the message.
    private func makeGRDBRecord() throws -> LXMFSwift.MessageRecord {
        var msg = LXMFSwift.LXMessage(
            destinationHash: Data([0xDE, 0xAD, 0x01]),  // arbitrary
            sourceHash: Data([0x50, 0x52, 0x43]),
            content: Data("body".utf8),
            title: Data("subj".utf8),
            timestamp: 1_650_000_000.25,
            state: .delivered,
            incoming: true
        )
        msg.hash = Data([0xAA, 0xBB, 0xCC])
        msg.method = .direct
        msg.rssi = -42.0
        msg.snr = 7.5
        msg.q = 0.9
        msg.receivingInterface = "TCPClient"
        // packed carries the MessagePack field map (A0 bridge convention).
        msg.fields = [LXMFSwift.LXMessage.FIELD_IMAGE: ["png", Data([0x89, 0x50])] as [Any]]
        msg.packed = LxmfFieldCodec.pack(msg.fields!)

        var rec = try LXMFSwift.MessageRecord(from: msg)
        // Columns init(from:) doesn't carry from the message:
        rec.replyToId = "deadbeef"
        rec.reactionsJson = "{\"👍\":[\"abc\"]}"
        return rec
    }

    func testMapRecordAllFields() throws {
        let rec = try makeGRDBRecord()
        let r = MessageRepository.mapRecord(rec)

        XCTAssertEqual(r.id, Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(r.messageId, Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(r.conversationHash, Data([0x50, 0x52, 0x43]))  // incoming → sourceHash
        XCTAssertEqual(r.content, Data("body".utf8))
        XCTAssertEqual(r.timestamp, 1_650_000_000.25, accuracy: 0.0001)  // Double passes through
        XCTAssertEqual(r.direction, .inbound)                            // incoming==true
        XCTAssertEqual(r.state, RNSAPI.LXMessageState.delivered.rawValue)  // enum<-UInt8 0x08
        XCTAssertEqual(r.method, RNSAPI.LXDeliveryMethod.direct.rawValue)  // enum<-UInt8 0x02
        XCTAssertEqual(r.sourceHash, Data([0x50, 0x52, 0x43]))
        XCTAssertEqual(r.rssi, -42.0)
        XCTAssertEqual(r.snr, 7.5)
        XCTAssertEqual(r.receivingInterface, "TCPClient")
        XCTAssertEqual(r.replyToId, "deadbeef")                          // String? passes through
        XCTAssertEqual(r.reactionsJson, "{\"👍\":[\"abc\"]}")
        // packed_lxmf passes through verbatim and is the field map the UI decodes.
        let decoded = LxmfFieldCodec.unpack(r.packedLxmf)
        XCTAssertNotNil(decoded?[LXMFSwift.LXMessage.FIELD_IMAGE], "field map should round-trip through packedLxmf")
    }

    func testMapToLXMessageRebuildsFromRecord() throws {
        let rec = try makeGRDBRecord()
        let m = MessageRepository.mapToLXMessage(rec)

        XCTAssertEqual(m.hash, Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(m.sourceHash, Data([0x50, 0x52, 0x43]))
        XCTAssertEqual(m.content, Data("body".utf8))
        XCTAssertEqual(m.title, Data("subj".utf8))
        XCTAssertEqual(m.timestamp, 1_650_000_000.25, accuracy: 0.0001)
        XCTAssertTrue(m.incoming)
        XCTAssertEqual(m.state, .delivered)
        XCTAssertEqual(m.method, .direct)
        XCTAssertEqual(m.rssi, -42.0)
        XCTAssertEqual(m.snr, 7.5)
        // Fields recovered from packedLxmf for attachment rendering.
        XCTAssertNotNil(m.fields?[LXMFSwift.LXMessage.FIELD_IMAGE])
    }

    // MARK: Icon mapping

    func testMapIcon() {
        let i = LXMFSwift.IconAppearance(iconName: "star", foregroundColor: "abcdef", backgroundColor: "012345")
        let r = MessageRepository.mapIcon(i)
        XCTAssertEqual(r.iconName, "star")
        XCTAssertEqual(r.foregroundColor, "abcdef")
        XCTAssertEqual(r.backgroundColor, "012345")
    }

    // MARK: packed_lxmf = field map vs LXMF wire (A0 follow-up #2)
    //
    // The chat UI recovers attachments/icons by running
    // `LxmfFieldCodec.unpack(record.packedLxmf)` (MessageBubble / Message(from:)).
    // App / Python-path rows store a MessagePack *field map* in `packed_lxmf`;
    // Swift / Network-Extension rows store the signed LXMF *wire* (LXMRouter
    // persists `LXMessage.packed`). The adapter must recover fields for BOTH so
    // attachments render uniformly. These tests drive the real production
    // adapter (`mapRecord` / `mapToLXMessage`) — no reimplementation.

    /// Common attachment/icon payload used by both the field-map and wire rows
    /// so the assertions are identical regardless of storage form.
    ///   FIELD_IMAGE (0x06)            = [format, bytes]
    ///   FIELD_FILE_ATTACHMENTS (0x05) = [[name, bytes], …]
    ///   FIELD_ICON_APPEARANCE (0x04)  = [name, fgRGB(3), bgRGB(3)]
    private static let imageBytes = Data([0x89, 0x50, 0x4E, 0x47])
    private static let fileBytes = Data([0x01, 0x02, 0x03, 0x04, 0x05])
    private func attachmentFields() -> [UInt8: Any] {
        [
            LXMFSwift.LXMessage.FIELD_IMAGE: ["png", Self.imageBytes] as [Any],
            LXMFSwift.LXMessage.FIELD_FILE_ATTACHMENTS: [["doc.txt", Self.fileBytes] as [Any]] as [Any],
            LXMFSwift.LXMessage.FIELD_ICON_APPEARANCE: ["account", Data([0xAA, 0xBB, 0xCC]), Data([0x11, 0x22, 0x33])] as [Any],
        ]
    }

    /// Assert the three attachment/icon fields survived recovery, matching the
    /// exact shape the chat UI (`MessageBubble`) extracts.
    private func assertAttachmentsRecovered(_ fields: [UInt8: Any]?, _ label: String) {
        guard let fields else { return XCTFail("\(label): no fields recovered") }

        // FIELD_IMAGE: [format, bytes]
        let image = fields[LXMFSwift.LXMessage.FIELD_IMAGE] as? [Any]
        XCTAssertEqual(image?.count, 2, "\(label): image field shape")
        XCTAssertEqual(image?[0] as? String, "png", "\(label): image format")
        XCTAssertEqual(image?[1] as? Data, Self.imageBytes, "\(label): image bytes")

        // FIELD_FILE_ATTACHMENTS: [[name, bytes]]
        let files = fields[LXMFSwift.LXMessage.FIELD_FILE_ATTACHMENTS] as? [Any]
        let firstFile = files?.first as? [Any]
        XCTAssertEqual(firstFile?[0] as? String, "doc.txt", "\(label): file name")
        XCTAssertEqual(firstFile?[1] as? Data, Self.fileBytes, "\(label): file bytes")

        // FIELD_ICON_APPEARANCE: [name, fgRGB, bgRGB]
        let icon = fields[LXMFSwift.LXMessage.FIELD_ICON_APPEARANCE] as? [Any]
        XCTAssertEqual(icon?.count, 3, "\(label): icon field shape")
        XCTAssertEqual(icon?[0] as? String, "account", "\(label): icon name")
        XCTAssertEqual(icon?[1] as? Data, Data([0xAA, 0xBB, 0xCC]), "\(label): icon fg")
        XCTAssertEqual(icon?[2] as? Data, Data([0x11, 0x22, 0x33]), "\(label): icon bg")
    }

    /// (a) A realistic FIELD-MAP row (app / Python path): `packed_lxmf` =
    /// `LxmfFieldCodec.pack(fields)`. Seeded onto a no-identity GRDB LXMessage
    /// exactly as `MessageRepository.mapToGRDBMessage` does.
    private func makeFieldMapRecord() throws -> LXMFSwift.MessageRecord {
        var msg = LXMFSwift.LXMessage(
            destinationHash: Data([0xDE, 0xAD, 0x10]),
            sourceHash: Data([0x50, 0x52, 0x43]),
            content: Data("body".utf8),
            title: Data("subj".utf8),
            timestamp: 1_650_000_000.25,
            state: .delivered,
            incoming: true
        )
        msg.hash = Data([0xAA, 0xBB, 0xCC])
        msg.method = .direct
        msg.fields = attachmentFields()
        msg.packed = LxmfFieldCodec.pack(msg.fields!)  // FIELD MAP, not wire
        return try LXMFSwift.MessageRecord(from: msg)
    }

    /// (b) A realistic WIRE row (Swift / NE path): a genuine LXMessage signed +
    /// packed to the on-wire format via the real pack path, then persisted —
    /// `MessageRecord.init(from:)` copies `LXMessage.packed` (the wire) into
    /// `packed_lxmf`, exactly like `LXMRouter` does on inbound delivery.
    private func makeWireRecord() throws -> (rec: LXMFSwift.MessageRecord, wire: Data) {
        // Real ReticulumSwift identity (re-exported via LXMFSwift) so `pack()`
        // can sign. Qualified to avoid the RNSAPI.Identity Compat-stub collision.
        // The destination hash value is irrelevant to field recovery — any
        // 16-byte value packs to valid wire.
        let sourceIdentity = ReticulumSwift.Identity()
        var msg = LXMFSwift.LXMessage(
            destinationHash: Data(repeating: 0xD7, count: 16),
            sourceIdentity: sourceIdentity,
            content: Data("hello".utf8),
            title: Data("subj".utf8),
            fields: attachmentFields(),
            desiredMethod: .direct
        )
        let wire = try msg.pack()  // genuine signed LXMF wire bytes
        // Sanity: this is wire (not a field map) — the field-map codec can't
        // read it, which is precisely the live bug this change fixes.
        XCTAssertNil(LxmfFieldCodec.unpack(wire),
                     "wire bytes must NOT decode as a field map (else no bug)")
        XCTAssertGreaterThan(wire.count, 96, "wire carries dest+src+sig header")
        let rec = try LXMFSwift.MessageRecord(from: msg)
        XCTAssertEqual(rec.packedLxmf, wire, "record must store the wire verbatim")
        return (rec, wire)
    }

    /// FIELD-MAP row → attachments recovered through BOTH adapter entry points.
    func testFieldMapRowRecoversAttachments() throws {
        let rec = try makeFieldMapRecord()

        // mapRecord → the UI runs LxmfFieldCodec.unpack(packedLxmf).
        let mr = MessageRepository.mapRecord(rec)
        assertAttachmentsRecovered(LxmfFieldCodec.unpack(mr.packedLxmf), "fieldmap/mapRecord")

        // mapToLXMessage → fields populated directly.
        let lx = MessageRepository.mapToLXMessage(rec)
        assertAttachmentsRecovered(lx.fields, "fieldmap/mapToLXMessage")
    }

    /// WIRE row → attachments recovered through BOTH adapter entry points.
    /// This is the regression target: before normalization the UI's
    /// `LxmfFieldCodec.unpack(packedLxmf)` returned nil on wire bytes, so
    /// Swift/NE-delivered images/files/icons silently didn't render.
    func testWireRowRecoversAttachments() throws {
        let (rec, _) = try makeWireRecord()

        // mapRecord must normalize wire → field map so the UI's unpack works.
        let mr = MessageRepository.mapRecord(rec)
        XCTAssertNotNil(LxmfFieldCodec.unpack(mr.packedLxmf),
                        "mapRecord must hand the UI a field map for wire rows")
        assertAttachmentsRecovered(LxmfFieldCodec.unpack(mr.packedLxmf), "wire/mapRecord")

        // mapToLXMessage must populate fields from the wire, and keep `packed`
        // coherent as a field map.
        let lx = MessageRepository.mapToLXMessage(rec)
        assertAttachmentsRecovered(lx.fields, "wire/mapToLXMessage")
        assertAttachmentsRecovered(LxmfFieldCodec.unpack(lx.packed ?? Data()), "wire/mapToLXMessage.packed")
    }

    func testReactionLedgerMakesReplayIdempotentAndHidesMetadata() {
        let first = ReactionLedger.applying(
            emoji: "👍",
            sender: "peer-a",
            reactionMessageHash: "reaction-1",
            to: [:]
        )
        XCTAssertTrue(first.didApply)
        XCTAssertEqual(first.state["👍"], ["peer-a"])
        XCTAssertEqual(ReactionLedger.visibleReactions(first.state), ["👍": ["peer-a"]])

        let replay = ReactionLedger.applying(
            emoji: "👍",
            sender: "peer-a",
            reactionMessageHash: "reaction-1",
            to: first.state
        )
        XCTAssertFalse(replay.didApply)
        XCTAssertEqual(replay.state, first.state, "replay must not toggle the reaction back off")

        let distinctToggle = ReactionLedger.applying(
            emoji: "👍",
            sender: "peer-a",
            reactionMessageHash: "reaction-2",
            to: replay.state
        )
        XCTAssertTrue(distinctToggle.didApply)
        XCTAssertNil(ReactionLedger.visibleReactions(distinctToggle.state)["👍"])
    }

    func testReactionMutationGateSerializesAcrossSuspensionPoints() async {
        let gate = ReactionMutationGate()
        let probe = ReactionGateProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.withLock {
                        await probe.enter()
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        await probe.leave()
                    }
                }
            }
        }

        let maximumActive = await probe.maximum()
        XCTAssertEqual(maximumActive, 1)
    }

    func testTelemetryDisplayNamePrefersCurrentLXMFAnnounceName() {
        XCTAssertEqual(
            TelemetryDisplayNameResolver.resolve(incoming: "Current Name", existing: "Older Name"),
            "Current Name"
        )
    }

    func testTelemetryDisplayNameRetainsExistingNameWhenFrameHasNoName() {
        XCTAssertEqual(
            TelemetryDisplayNameResolver.resolve(incoming: nil, existing: "Known Peer"),
            "Known Peer"
        )
        XCTAssertEqual(
            TelemetryDisplayNameResolver.resolve(incoming: "   ", existing: "Known Peer"),
            "Known Peer"
        )
    }

    func testTelemetryDisplayNameRemainsNilWhenNoNameHasBeenResolved() {
        XCTAssertNil(TelemetryDisplayNameResolver.resolve(incoming: nil, existing: nil))
    }

    func testTelemetryDiagnosticNameIsSingleLineJSON() throws {
        let encoded = TelemetryDisplayNameResolver.diagnosticValue("Peer \"North\"\nInjected")
        XCTAssertEqual(encoded, "\"Peer \\\"North\\\"\\nInjected\"")
        XCTAssertFalse(encoded.contains("\n"))
        XCTAssertEqual(
            try JSONDecoder().decode(String.self, from: Data(encoded.utf8)),
            "Peer \"North\"\nInjected"
        )
    }

    // Note: the empty/field-map/wire discriminator is covered through the public
    // adapters by testFieldMapRowRecoversAttachments + testWireRowRecoversAttachments
    // (which call mapRecord/mapToLXMessage -> the internal recoverFields/normalizedFieldMap).
}
