import XCTest
@testable import RNSAPI

final class MessageRendererTests: XCTestCase {
    func testMarkdownRequiresExactIntegerRendererField() {
        XCTAssertEqual(
            MessageRenderer(fields: [LxmfFields.FIELD_RENDERER: 2]),
            .markdown
        )
    }

    func testUnsupportedOrMalformedRendererValuesRemainPlaintext() {
        let cases: [[UInt8: Any]?] = [
            nil,
            [:],
            [LxmfFields.FIELD_RENDERER: 0],
            [LxmfFields.FIELD_RENDERER: 1],
            [LxmfFields.FIELD_RENDERER: 3],
            [LxmfFields.FIELD_RENDERER: 99],
            [LxmfFields.FIELD_RENDERER: "2"],
            [LxmfFields.FIELD_RENDERER: 2.0],
            [LxmfFields.FIELD_RENDERER: true],
            [LxmfFields.FIELD_RENDERER: Data([2])],
        ]

        for fields in cases {
            XCTAssertEqual(MessageRenderer(fields: fields), .plain)
        }
    }
}
