import XCTest
@testable import ColumbaApp

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

    func testHeadingLevelCappedAt3() {
        let doc = MicronParser.parse(">>>>TooDeep")
        guard case .heading(let level, _, _) = doc.elements.first else {
            XCTFail("Expected heading"); return
        }
        XCTAssertEqual(level, 3)
    }

    // MARK: - Dividers

    func testDefaultDivider() {
        let doc = MicronParser.parse("-")
        guard case .divider(let ch) = doc.elements.first else {
            XCTFail("Expected divider"); return
        }
        XCTAssertNil(ch)
    }

    func testCustomDivider() {
        let doc = MicronParser.parse("-=")
        guard case .divider(let ch) = doc.elements.first else {
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
        guard case .literalBlock(let text) = doc.elements.first else {
            XCTFail("Expected literal block"); return
        }
        XCTAssertEqual(text, "foo\nbar")
    }

    func testUnclosedLiteralBlock() {
        let doc = MicronParser.parse("`=\nsome code")
        guard case .literalBlock(let text) = doc.elements.first else {
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
        guard case .formField(let field) = formElements[0] else { XCTFail("Expected form field"); return }
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
        guard case .formField(let field) = formElements[0] else { XCTFail("Expected form field"); return }
        guard case .passwordInput(let name, _) = field else {
            XCTFail("Expected password input"); return
        }
        XCTAssertEqual(name, "password")
    }

    func testCheckbox() {
        let doc = MicronParser.parse("`<?|option|yes`>Accept terms")
        let formElements = doc.elements.filter { if case .formField = $0 { return true }; return false }
        XCTAssertEqual(formElements.count, 1)
        guard case .formField(let field) = formElements[0] else { XCTFail("Expected form field"); return }
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
        guard case .formField(let field) = formElements[0] else { XCTFail("Expected form field"); return }
        guard case .checkbox(_, _, _, let checked) = field else {
            XCTFail("Expected checkbox"); return
        }
        XCTAssertTrue(checked)
    }

    func testRadioButton() {
        let doc = MicronParser.parse("`<^|choice|a`>Option A")
        let formElements = doc.elements.filter { if case .formField = $0 { return true }; return false }
        XCTAssertEqual(formElements.count, 1)
        guard case .formField(let field) = formElements[0] else { XCTFail("Expected form field"); return }
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
        guard case .formField(let field) = formElements[0] else { XCTFail("Expected form field"); return }
        guard case .radio(_, _, _, let selected) = field else {
            XCTFail("Expected radio"); return
        }
        XCTAssertTrue(selected)
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
