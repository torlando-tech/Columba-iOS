import SwiftUI
import UIKit
import XCTest
@testable import ColumbaApp

final class MessageBubbleLayoutTests: XCTestCase {

    @MainActor
    func testReplyBubbleUsesContentHeightAndPreservesLongMessageBody() throws {
        let message = Message(
            content: "Test response: this sentence is intentionally long enough to wrap across several lines. The complete sent message must remain visible below its reply preview without truncation.",
            timestamp: Date(),
            isFromMe: true,
            deliveryStatus: .delivered,
            replyToId: "reply-target",
            replyToPreview: "That narrows it down to the iOS rendering path for received responses, not outbound transport."
        )
        let host = UIHostingController(
            rootView: MessageBubble(message: message)
                .frame(width: 390)
        )

        let fitted = host.sizeThatFits(
            in: CGSize(width: 390, height: 1_000)
        )

        XCTAssertGreaterThan(
            fitted.height,
            150,
            "The reply preview and wrapped body must both contribute to bubble height"
        )
        XCTAssertLessThan(
            fitted.height,
            400,
            "The reply indicator must not greedily expand to the parent's proposed height"
        )

        let renderer = ImageRenderer(
            content: MessageBubble(message: message)
                .frame(width: 390)
                .padding()
                .background(Color.black)
        )
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "reply-bubble-long-message"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
