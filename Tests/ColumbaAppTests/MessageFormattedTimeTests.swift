import XCTest
@testable import ColumbaApp

final class MessageFormattedTimeTests: XCTestCase {

    func test_formattedTime_clampsFutureTimestampToNow() {
        let future = Date().addingTimeInterval(600)
        let message = Message(content: "hi", timestamp: future, isFromMe: true)

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let referenceNow = Date()
        let expected = formatter.localizedString(for: referenceNow, relativeTo: referenceNow)

        XCTAssertEqual(message.formattedTime, expected)
    }

    func test_formattedTime_pastTimestampsRenderRelativePast() {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let message = Message(content: "hi", timestamp: oneHourAgo, isFromMe: false)

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let expected = formatter.localizedString(for: oneHourAgo, relativeTo: Date())

        XCTAssertEqual(message.formattedTime, expected)
    }
}
