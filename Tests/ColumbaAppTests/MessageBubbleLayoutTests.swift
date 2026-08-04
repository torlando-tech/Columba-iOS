import SwiftUI
import UIKit
import XCTest
@testable import ColumbaApp

final class MessageBubbleLayoutTests: XCTestCase {

    private func accessibilityIdentifiers(in root: UIView) -> Set<String> {
        var identifiers = Set<String>()
        var visited = Set<ObjectIdentifier>()

        func visit(_ object: AnyObject) {
            let identifier = ObjectIdentifier(object)
            guard visited.insert(identifier).inserted else { return }

            if let identifiable = object as? UIAccessibilityIdentification,
               let value = identifiable.accessibilityIdentifier,
               !value.isEmpty {
                identifiers.insert(value)
            }
            if let view = object as? UIView {
                for child in view.subviews {
                    visit(child)
                }
                for child in view.accessibilityElements ?? [] {
                    visit(child as AnyObject)
                }
            }
        }

        visit(root)
        return identifiers
    }

    @MainActor
    func testMessageTextScaleChangesRenderedBodyHeight() throws {
        let message = Message(
            content: "A longer message body that wraps across multiple lines so the selected conversation text size has a measurable effect on the rendered bubble height.",
            timestamp: Date(),
            isFromMe: false,
            deliveryStatus: .delivered
        )
        let smallHost = UIHostingController(
            rootView: MessageBubble(message: message, messageTextScale: 0.7)
                .frame(width: 320)
        )
        let largeHost = UIHostingController(
            rootView: MessageBubble(message: message, messageTextScale: 2.0)
                .frame(width: 320)
        )

        let proposal = CGSize(width: 320, height: 1_000)
        let small = smallHost.sizeThatFits(in: proposal)
        let large = largeHost.sizeThatFits(in: proposal)

        XCTAssertGreaterThan(
            large.height,
            small.height + 60,
            "The 200% setting must visibly enlarge the message body relative to 70%"
        )

        for (name, scale) in [("70-percent", 0.7), ("100-percent", 1.0), ("200-percent", 2.0)] {
            let renderer = ImageRenderer(
                content: MessageBubble(message: message, messageTextScale: scale)
                    .frame(width: 320)
                    .padding()
                    .background(Color.black)
            )
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            let screenshot = XCTAttachment(image: image)
            screenshot.name = "message-text-size-\(name)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testTextSizePickerRendersCompleteControls() throws {
        let size = CGSize(width: 390, height: 460)
        let host = UIHostingController(
            rootView: TextSizePickerSheet(currentScale: 1.0, onSave: { _ in })
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()

        let identifiers = accessibilityIdentifiers(in: host.view)
        let expectedIdentifiers: Set<String> = [
            "text_size_preview",
            "text_size_percent",
            "text_size_slider",
            "text_size_range_labels",
            "text_size_cancel",
            "text_size_confirm"
        ]
        XCTAssertTrue(
            expectedIdentifiers.isSubset(of: identifiers),
            "Missing picker controls: \(expectedIdentifiers.subtracting(identifiers).sorted())"
        )

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }

        XCTAssertEqual(image.size.width, 390, accuracy: 1)
        XCTAssertEqual(image.size.height, 460, accuracy: 1)

        let screenshot = XCTAttachment(image: image)
        screenshot.name = "message-text-size-picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

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
        let bodyOnlyMessage = Message(
            content: message.content,
            timestamp: message.timestamp,
            isFromMe: message.isFromMe,
            deliveryStatus: message.deliveryStatus
        )
        let bodyOnlyHost = UIHostingController(
            rootView: MessageBubble(message: bodyOnlyMessage)
                .frame(width: 390)
        )
        let bodyOnlyFitted = bodyOnlyHost.sizeThatFits(
            in: CGSize(width: 390, height: 1_000)
        )

        XCTAssertGreaterThan(
            fitted.height,
            bodyOnlyFitted.height + 25,
            "The reply bubble must retain the full body height plus visible reply context"
        )
        XCTAssertLessThan(
            fitted.height,
            400,
            "The reply indicator must not greedily expand to the parent's proposed height"
        )

        var scaledHeights: [Double: CGFloat] = [:]
        for (name, scale) in [("70-percent", 0.7), ("100-percent", 1.0), ("200-percent", 2.0)] {
            let scaledHost = UIHostingController(
                rootView: MessageBubble(message: message, messageTextScale: scale)
                    .frame(width: 390)
            )
            scaledHeights[scale] = scaledHost.sizeThatFits(
                in: CGSize(width: 390, height: 2_000)
            ).height

            let renderer = ImageRenderer(
                content: MessageBubble(message: message, messageTextScale: scale)
                    .frame(width: 390)
                    .padding()
                    .background(Color.black)
            )
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            let screenshot = XCTAttachment(image: image)
            screenshot.name = "reply-bubble-message-text-size-\(name)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        XCTAssertGreaterThan(
            try XCTUnwrap(scaledHeights[2.0]),
            try XCTUnwrap(scaledHeights[0.7]) + 60,
            "Reply bubbles must retain the visibly scaled primary body at both extremes"
        )
    }
}
