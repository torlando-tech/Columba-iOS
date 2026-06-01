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
        // 2 hours is comfortably mid-bucket for the abbreviated formatter. The
        // 60-min mark is a min/hr rounding boundary, so a 1-hr offset could let
        // the two independent Date() reads (here vs. inside formattedTime)
        // straddle it and flake. Anchor `now` once for the expected value.
        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-7200)
        let message = Message(content: "hi", timestamp: twoHoursAgo, isFromMe: false)

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let expected = formatter.localizedString(for: twoHoursAgo, relativeTo: now)

        XCTAssertEqual(message.formattedTime, expected)
    }
}
