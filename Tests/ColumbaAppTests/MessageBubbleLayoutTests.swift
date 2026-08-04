import SwiftUI
import UIKit
import XCTest
import RNSAPI
@testable import ColumbaApp

final class MessageLinkParserTests: XCTestCase {
    private let nodeHash = "9ce92808be498e9e05590ff27cbfdfe4"

    func testPlaintextDetectsWebAndBareNomadNetLinksWithoutTrailingPunctuation() {
        let text = "Open https://example.com/docs, then \(nodeHash):/page/index.mu."
        let matches = MessageLinkParser.matches(in: text)

        XCTAssertEqual(matches.map(\.text), [
            "https://example.com/docs",
            "\(nodeHash):/page/index.mu",
        ])
        XCTAssertEqual(matches.map(\.target), [
            .web(URL(string: "https://example.com/docs")!),
            .nomadNet(nodeHash: Data(hexString: nodeHash)!, path: "/page/index.mu"),
        ])
    }

    func testMarkdownLinkTargetsAllowOnlySupportedSchemes() {
        XCTAssertEqual(
            MessageLinkParser.target(for: URL(string: "https://example.com")!),
            .web(URL(string: "https://example.com")!)
        )
        XCTAssertEqual(
            MessageLinkParser.target(for: URL(string: "nomadnetwork://\(nodeHash):/page/index.mu")!),
            .nomadNet(nodeHash: Data(hexString: nodeHash)!, path: "/page/index.mu")
        )
        XCTAssertNotNil(
            MessageLinkParser.target(for: URL(string: "lxma://contact?destination=abc")!)
        )
        XCTAssertNil(MessageLinkParser.target(for: URL(string: "file:///tmp/private")!))
        XCTAssertNil(MessageLinkParser.target(for: URL(string: "javascript:alert(1)")!))
        XCTAssertNil(MessageLinkParser.target(for: URL(string: "data:text/plain,secret")!))
    }

    func testBareHashWithoutNomadNetPathIsNotLinkified() {
        XCTAssertTrue(MessageLinkParser.matches(in: "identity \(nodeHash)").isEmpty)
    }

    func testInlineMarkdownImagesAreRejectedWithoutLoading() async {
        let provider = BlockedMarkdownInlineImageProvider()

        do {
            _ = try await provider.image(
                with: URL(string: "https://tracking.example/pixel.png")!,
                label: "tracking pixel"
            )
            XCTFail("Expected remote Markdown image to be blocked")
        } catch is BlockedMarkdownInlineImageProvider.Blocked {
            // Expected: the provider performs no network operation.
        } catch {
            XCTFail("Unexpected image-provider error: \(error)")
        }
    }
}

final class MessageRendererMappingTests: XCTestCase {
    func testLiveMessageCarriesAuthenticatedMarkdownRenderer() {
        let lxMessage = LXMessage(
            destinationHash: Data(repeating: 0x01, count: 16),
            sourceIdentity: nil,
            content: Data("**rendered**".utf8),
            fields: [LxmfFields.FIELD_RENDERER: LxmfFields.RENDERER_MARKDOWN]
        )
        lxMessage.hash = Data(repeating: 0x02, count: 32)

        XCTAssertEqual(
            Message(from: lxMessage, localHash: Data()).renderer,
            .markdown
        )
    }

    func testPersistedMessageRestoresMarkdownRenderer() {
        let fields: [UInt8: Any] = [
            LxmfFields.FIELD_RENDERER: LxmfFields.RENDERER_MARKDOWN,
        ]
        let record = MessageRecord(
            id: Data(repeating: 0x03, count: 32),
            conversationHash: Data(repeating: 0x04, count: 16),
            content: Data("# Restored".utf8),
            timestamp: 1,
            direction: .inbound,
            state: LXMessageState.received.rawValue,
            messageId: Data(repeating: 0x03, count: 32),
            packedLxmf: LxmfFieldCodec.pack(fields)
        )

        XCTAssertEqual(
            Message(from: record, localHash: Data()).renderer,
            .markdown
        )
    }
}

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
    func testMarkdownAndPlaintextMessageRenderingProducesVisualEvidence() throws {
        let markdown = """
        # Markdown message

        This is **bold**, *emphasized*, and ~~removed~~ text with `inline code`.

        - First item
        - Second item

        > Authenticated Markdown renderer field

        [HTTPS link](https://example.com/docs) and [NomadNet page](nomadnetwork://9ce92808be498e9e05590ff27cbfdfe4:/page/index.mu)

        ![remote tracking image](https://tracking.example/pixel.png)

        <script>alert('inert')</script>
        """
        let messages = [
            Message(
                content: markdown,
                timestamp: Date(),
                isFromMe: false,
                deliveryStatus: .delivered,
                renderer: .markdown
            ),
            Message(
                content: "Plaintext gate: **not bold** https://example.com/docs",
                timestamp: Date(),
                isFromMe: true,
                deliveryStatus: .delivered,
                renderer: .plain
            ),
        ]
        let view = VStack(spacing: 16) {
            ForEach(messages) { message in
                MessageBubble(message: message, onOpenLink: { _ in })
            }
        }
        .frame(width: 390)
        .padding(.vertical, 20)
        .background(Color.black)
        let host = UIHostingController(rootView: view)
        let fitted = host.sizeThatFits(in: CGSize(width: 390, height: 2_000))

        XCTAssertGreaterThan(fitted.height, 300)
        XCTAssertLessThan(fitted.height, 1_500)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "markdown-and-plaintext-message-bubbles"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
    }

    func testRefreshWindowExpandsUntilPriorOldestRecordIsRetained() {
        XCTAssertEqual(
            MessageRefreshWindowPolicy.expandedLimit(
                currentLimit: 51,
                fetchedCount: 51,
                containsPriorOldest: false,
                pageSize: 50
            ),
            101
        )
        XCTAssertNil(
            MessageRefreshWindowPolicy.expandedLimit(
                currentLimit: 101,
                fetchedCount: 101,
                containsPriorOldest: true,
                pageSize: 50
            )
        )
        XCTAssertNil(
            MessageRefreshWindowPolicy.expandedLimit(
                currentLimit: 101,
                fetchedCount: 75,
                containsPriorOldest: false,
                pageSize: 50
            )
        )
        XCTAssertEqual(
            MessageRefreshWindowPolicy.retainedPrefixCount(
                recordIDs: ["new", "prior-oldest", "speculative-older"],
                priorOldestID: "prior-oldest"
            ),
            2
        )
        XCTAssertEqual(
            MessageRefreshWindowPolicy.retainedPrefixCount(
                recordIDs: ["newest", "middle", "prior-oldest"],
                priorOldestID: "prior-oldest"
            ),
            3
        )
    }

    func testDeleteIsUnavailableUntilOutboundPersistenceCompletes() {
        XCTAssertFalse(
            MessagingViewModel.canDeleteMessage(
                isUnpersisted: true,
                isUnsavedFailure: false
            )
        )
        XCTAssertTrue(
            MessagingViewModel.canDeleteMessage(
                isUnpersisted: true,
                isUnsavedFailure: true
            )
        )
        XCTAssertTrue(
            MessagingViewModel.canDeleteMessage(
                isUnpersisted: false,
                isUnsavedFailure: false
            )
        )
    }

    func testDeliveryProofUsesOptimisticAliasDuringPersistence() {
        XCTAssertEqual(
            MessagingViewModel.visibleMessageID(
                for: "real-hash",
                aliases: ["real-hash": "optimistic-id"]
            ),
            "optimistic-id"
        )
        XCTAssertEqual(
            MessagingViewModel.visibleMessageID(for: "persisted-hash", aliases: [:]),
            "persisted-hash"
        )
        XCTAssertEqual(
            MessagingViewModel.pendingProof(
                forVisibleID: "optimistic-id",
                aliases: ["real-hash": "optimistic-id"],
                proofs: ["real-hash": .delivered]
            ),
            .delivered
        )
    }

    func testPersistedAliasedProofCanonicalizesVisibleIdentityAndActions() {
        let storageHash = Data(repeating: 0x41, count: 32)
        let canonicalHash = Data(repeating: 0x42, count: 32)
        var uncertain = Message(
            id: storageHash.map { String(format: "%02x", $0) }.joined(),
            content: "delivered after recovery",
            isFromMe: true,
            deliveryStatus: .failed,
            storageHash: storageHash,
            isTargetSafe: false
        )
        uncertain.messageHash = canonicalHash

        let canonical = MessagingViewModel.canonicalizedMessage(
            uncertain,
            canonicalHash: canonicalHash,
            proofState: .delivered
        )

        let canonicalID = canonicalHash.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(canonical.id, canonicalID)
        XCTAssertEqual(canonical.storageHash, canonicalHash)
        XCTAssertEqual(canonical.messageHash, canonicalHash)
        XCTAssertEqual(canonical.deliveryStatus, .delivered)
        XCTAssertTrue(canonical.isTargetSafe)
        XCTAssertTrue(
            MessagingViewModel.canDeleteMessage(
                isUnpersisted: false,
                isUnsavedFailure: false
            )
        )
    }

    func testRefreshPreservesOnlyUnpersistedOutboundRowsInTimelineOrder() {
        let base = Date(timeIntervalSince1970: 1_000)
        let oldest = Message(id: "oldest", content: "Oldest", timestamp: base, isFromMe: false)
        let pendingA = Message(
            id: "pending-a",
            content: "Pending A",
            timestamp: base.addingTimeInterval(1),
            isFromMe: true
        )
        let loadedB = Message(
            id: "persisted-b",
            content: "Staged database row",
            timestamp: base.addingTimeInterval(2),
            isFromMe: true
        )
        let pendingB = Message(
            id: "persisted-b",
            content: "Current pending row",
            timestamp: base.addingTimeInterval(2),
            isFromMe: true
        )
        let stale = Message(id: "stale", content: "Stale", timestamp: base, isFromMe: false)

        let merged = MessagingViewModel.mergingPendingOutbound(
            loaded: [oldest, loadedB],
            current: [stale, pendingA, pendingB],
            pendingIDs: ["pending-a", "persisted-b"]
        )

        XCTAssertEqual(merged.map(\.id), ["oldest", "pending-a", "persisted-b"])
        XCTAssertEqual(merged.last?.content, "Current pending row")
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

        controller.update(
            messages: messages,
            messageTextScale: 1.3,
            isLoadingMore: false,
            allMessagesLoaded: true
        )
        controller.setViewportForTesting(CGSize(width: 390, height: 380))
        controller.setViewportForTesting(CGSize(width: 390, height: 700))

        XCTAssertEqual(controller.renderedMessageCount, 50)
        XCTAssertEqual(controller.configuredMessageTextScale, 1.3)
        XCTAssertGreaterThan(controller.visibleMessageCellCount, 0)
    }

    @MainActor
    func testCollectionTimelineRequestsHistoryFromScrollOffset() async {
        let requested = expectation(description: "older page requested")
        let controller = MessageTimelineViewController()
        controller.onLoadOlder = {
            controller.update(messages: [], isLoadingMore: false, allMessagesLoaded: true)
            requested.fulfill()
            return true
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

    @MainActor
    func testCollectionTimelineDoesNotRetryRejectedHistoryLoad() async {
        var requestCount = 0
        let controller = MessageTimelineViewController()
        controller.onLoadOlder = {
            requestCount += 1
            return false
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
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(requestCount, 1)
    }
}
