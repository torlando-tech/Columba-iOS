import SwiftUI
import UIKit
import XCTest
@testable import ColumbaApp

final class MessageBubbleLayoutTests: XCTestCase {

    private func visibleContentBounds(in image: UIImage) throws -> CGRect {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let brightness = Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
                if brightness > 75 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            XCTFail("Picker rendering contains no visible controls")
            return .zero
        }
        let scale = image.scale
        return CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
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

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }

        XCTAssertEqual(image.size.width, 390, accuracy: 1)
        XCTAssertEqual(image.size.height, 460, accuracy: 1)
        let contentBounds = try visibleContentBounds(in: image)
        XCTAssertGreaterThan(contentBounds.width, 280)
        XCTAssertGreaterThan(contentBounds.height, 280)
        XCTAssertLessThan(contentBounds.minY, 90)
        XCTAssertLessThan(
            contentBounds.maxY,
            size.height - 8,
            "Text-size controls must retain visible bottom padding instead of clipping"
        )

        let screenshot = XCTAttachment(image: image)
        screenshot.name = "message-text-size-picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let accessibilitySize = CGSize(width: 320, height: 700)
        let accessibilityHost = UIHostingController(
            rootView: TextSizePickerSheet(currentScale: 1.0, onSave: { _ in })
                .dynamicTypeSize(.accessibility2)
        )
        let accessibilityWindow = UIWindow(frame: CGRect(origin: .zero, size: accessibilitySize))
        accessibilityWindow.rootViewController = accessibilityHost
        accessibilityWindow.makeKeyAndVisible()
        defer { accessibilityWindow.isHidden = true }
        accessibilityHost.view.frame = CGRect(origin: .zero, size: accessibilitySize)
        accessibilityHost.view.layoutIfNeeded()
        let accessibilityImage = UIGraphicsImageRenderer(size: accessibilitySize).image { _ in
            accessibilityHost.view.drawHierarchy(
                in: accessibilityHost.view.bounds,
                afterScreenUpdates: true
            )
        }
        let accessibilityBounds = try visibleContentBounds(in: accessibilityImage)
        XCTAssertGreaterThan(accessibilityBounds.width, 270)
        XCTAssertGreaterThan(accessibilityBounds.height, 300)
        XCTAssertLessThan(accessibilityBounds.maxY, accessibilitySize.height - 8)

        let accessibilityScreenshot = XCTAttachment(image: accessibilityImage)
        accessibilityScreenshot.name = "message-text-size-picker-accessibility-narrow"
        accessibilityScreenshot.lifetime = .keepAlways
        add(accessibilityScreenshot)
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

final class MessageTimelinePolicyTests: XCTestCase {

    func testPaginationStartsBeforeTopWithoutViewLifecycleSentinel() {
        XCTAssertTrue(
            MessageTimelinePaginationPolicy.shouldLoadOlder(
                contentOffsetY: 1_499,
                viewportHeight: 500,
                isLoading: false,
                allHistoryLoaded: false
            )
        )
        XCTAssertFalse(
            MessageTimelinePaginationPolicy.shouldLoadOlder(
                contentOffsetY: 1_500,
                viewportHeight: 500,
                isLoading: false,
                allHistoryLoaded: false
            )
        )
    }

    func testPaginationRejectsDuplicateAndExhaustedLoads() {
        XCTAssertFalse(
            MessageTimelinePaginationPolicy.shouldLoadOlder(
                contentOffsetY: 0,
                viewportHeight: 500,
                isLoading: true,
                allHistoryLoaded: false
            )
        )
        XCTAssertFalse(
            MessageTimelinePaginationPolicy.shouldLoadOlder(
                contentOffsetY: 0,
                viewportHeight: 500,
                isLoading: false,
                allHistoryLoaded: true
            )
        )
    }

    func testPrependingMessagesPreservesVisibleAnchorOffset() {
        XCTAssertEqual(
            MessageTimelineViewportAnchor.adjustedContentOffset(
                previousContentOffset: 1_200,
                previousAnchorMinY: 1_260,
                updatedAnchorMinY: 2_010
            ),
            1_950,
            accuracy: 0.001
        )
    }

    func testPaginationCursorUsesFetchedRecordsRatherThanVisibleMessages() {
        var cursor = MessagePageCursor()
        cursor.recordFetchedPage(recordCount: 50)

        // A page may contain telemetry records that are intentionally hidden
        // from the timeline. The next database offset must still skip all 50
        // records, not the smaller number of visible message bubbles.
        XCTAssertEqual(cursor.nextOffset, 50)

        cursor.recordFetchedPage(recordCount: 50)
        XCTAssertEqual(cursor.nextOffset, 100)

        cursor.recordInsertedAtNewest()
        XCTAssertEqual(cursor.nextOffset, 101)
    }

    @MainActor
    func testCollectionTimelineKeepsRowsRenderedAcrossViewportChanges() {
        let controller = MessageTimelineViewController()
        controller.loadViewIfNeeded()
        controller.setViewportForTesting(CGSize(width: 390, height: 700))

        var messages: [Message] = []
        for index in 0..<50 {
            let replyID: String? = index == 0 ? nil : "message-\(index - 1)"
            let replyPreview: String? = index == 0 ? nil : "Earlier message preview"
            messages.append(
                Message(
                    id: "message-\(index)",
                    content: String(repeating: "Long timeline content \(index). ", count: 8),
                    timestamp: Date().addingTimeInterval(TimeInterval(index)),
                    isFromMe: index.isMultiple(of: 2),
                    deliveryStatus: .delivered,
                    replyToId: replyID,
                    replyToPreview: replyPreview
                )
            )
        }

        controller.update(messages: messages, isLoadingMore: false, allMessagesLoaded: true)
        controller.setViewportForTesting(CGSize(width: 390, height: 380))
        controller.setViewportForTesting(CGSize(width: 390, height: 700))

        XCTAssertEqual(controller.renderedMessageCount, 50)
        XCTAssertGreaterThan(controller.visibleMessageCellCount, 0)
    }

    @MainActor
    func testCollectionTimelineRequestsHistoryFromScrollOffset() async {
        let requested = expectation(description: "older page requested")
        let controller = MessageTimelineViewController()
        controller.onLoadOlder = {
            controller.update(messages: [], isLoadingMore: false, allMessagesLoaded: true)
            requested.fulfill()
        }
        controller.loadViewIfNeeded()
        controller.setViewportForTesting(CGSize(width: 390, height: 700))
        controller.update(
            messages: (0..<50).map {
                Message(id: "message-\($0)", content: "Message \($0)", isFromMe: false)
            },
            isLoadingMore: false,
            allMessagesLoaded: false
        )

        controller.setContentOffsetForTesting(y: 0)
        await fulfillment(of: [requested], timeout: 1)
    }
}
