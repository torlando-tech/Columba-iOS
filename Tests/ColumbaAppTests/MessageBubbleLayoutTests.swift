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

    func testPlaintextDetectsCanonicalLXMAContactLink() throws {
        let destinationHash = String(repeating: "01", count: 16)
        let publicKey = String(repeating: "ab", count: 64)
        let lxma = "lxma://\(destinationHash):\(publicKey)"

        let match = try XCTUnwrap(MessageLinkParser.matches(in: "Add \(lxma) now").first)

        let actionURL = try XCTUnwrap(URL(string: "lxma:\(destinationHash):\(publicKey)"))
        XCTAssertEqual(match.text, lxma)
        XCTAssertEqual(match.target, .external(actionURL))
        XCTAssertEqual(match.target.url, actionURL)
        XCTAssertEqual(MessageLinkParser.target(for: actionURL), .external(actionURL))
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

    func testSharedNomadNetAddressPreservesEncodedRequestVariables() throws {
        let address = "nomadnetwork://\(nodeHash):/page/group.mu`g=reticulum|delimiter=a%7Cb|equals=a%3Db|plus=a%2Bb|percent=a%25b"
        let url = try XCTUnwrap(URL(string: address))

        XCTAssertEqual(
            MessageLinkParser.target(for: url),
            .nomadNet(
                nodeHash: Data(hexString: nodeHash)!,
                path: "/page/group.mu`g=reticulum|delimiter=a%7Cb|equals=a%3Db|plus=a%2Bb|percent=a%25b"
            )
        )
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

@MainActor
final class ComposerReturnKeyPresentationTests: XCTestCase {
    private final class SendCounter {
        var value = 0
    }

    private final class ComposerState {
        var text = "Hello"
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { subview in
            (subview as? T).map { [$0] } ?? [] + descendants(of: type, in: subview)
        }
    }

    private func hostedComposer(sendsOnReturn: Bool) throws -> (UIWindow, UITextView, ComposerState, SendCounter) {
        UserDefaults.standard.set(sendsOnReturn, forKey: ComposerKeyboardPreference.key)
        let state = ComposerState()
        let counter = SendCounter()
        let host = UIHostingController(rootView: MessageInputBar(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            attachedImage: .constant(nil),
            attachedFiles: .constant([]),
            onSend: { counter.value += 1 },
            onImagePicker: {},
            onAttachment: {}
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        let field = try XCTUnwrap(
            descendants(of: UITextView.self, in: host.view)
                .first(where: { $0.accessibilityIdentifier == "message_composer" })
        )
        return (window, field, state, counter)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ComposerKeyboardPreference.key)
        super.tearDown()
    }

    func testDefaultReturnKeyPresentsSendAndSubmitsMessage() throws {
        let (window, field, state, counter) = try hostedComposer(sendsOnReturn: true)
        defer {
            window.isHidden = true
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        withExtendedLifetime(window) {
            XCTAssertEqual(field.returnKeyType, .send)
            XCTAssertEqual(field.accessibilityLabel, "Type a message...")
            let shouldInsertNewline = field.delegate?.textView?(
                field,
                shouldChangeTextIn: NSRange(location: field.text.count, length: 0),
                replacementText: "\n"
            )
            XCTAssertEqual(shouldInsertNewline, false)
            XCTAssertEqual(counter.value, 1)
            XCTAssertEqual(state.text, "Hello")
        }
    }

    func testMarkedTextIsCommittedInsteadOfSending() throws {
        let (window, field, _, counter) = try hostedComposer(sendsOnReturn: true)
        defer {
            window.isHidden = true
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        withExtendedLifetime(window) {
            field.setMarkedText("候", selectedRange: NSRange(location: 1, length: 0))
            XCTAssertNotNil(field.markedTextRange)

            let shouldCommitMarkedText = field.delegate?.textView?(
                field,
                shouldChangeTextIn: NSRange(location: field.text.count, length: 0),
                replacementText: "\n"
            )

            XCTAssertEqual(shouldCommitMarkedText, true)
            XCTAssertEqual(counter.value, 0)
        }
    }

    func testPastedSingleNewlineIsInsertedWithoutSending() throws {
        let pasteboard = UIPasteboard.general
        let previousItems = pasteboard.items
        let (window, field, state, counter) = try hostedComposer(sendsOnReturn: true)
        defer {
            pasteboard.items = previousItems
            window.isHidden = true
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        pasteboard.string = "\n"
        XCTAssertTrue(field.becomeFirstResponder())
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        field.selectedRange = NSRange(location: field.text.count, length: 0)
        field.paste(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(field.text, "Hello\n")
        XCTAssertEqual(state.text, "Hello\n")
    }

    func testNewlinePreferencePresentsReturnWithoutSubmitting() throws {
        let (window, field, state, counter) = try hostedComposer(sendsOnReturn: false)
        defer {
            window.isHidden = true
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        withExtendedLifetime(window) {
            XCTAssertEqual(field.returnKeyType, .default)
            let shouldInsertNewline = field.delegate?.textView?(
                field,
                shouldChangeTextIn: NSRange(location: field.text.count, length: 0),
                replacementText: "\n"
            )
            XCTAssertEqual(shouldInsertNewline, true)
            XCTAssertEqual(counter.value, 0)
            XCTAssertEqual(state.text, "Hello")
        }
    }
}

final class MessageBubbleLayoutTests: XCTestCase {

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { subview in
            (subview as? T).map { [$0] } ?? [] + descendants(of: type, in: subview)
        }
    }

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

        ```swift
        struct Peer {
            let name: String
            let isReachable: Bool
        }

        let peer = Peer(name: "Columba", isReachable: true)
        print(peer.name)
        let routeDescription = peers.filter { $0.isReachable }.map { "\\($0.name):authenticated-reticulum-route" }.joined(separator: " -> ")
        ```

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
        let initialSize = CGSize(width: 390, height: 2_000)
        let window = UIWindow(frame: CGRect(origin: .zero, size: initialSize))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = CGRect(origin: .zero, size: initialSize)
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let fitted = host.sizeThatFits(in: initialSize)
        XCTAssertGreaterThan(fitted.height, 300)
        XCTAssertLessThan(fitted.height, 1_500)

        let size = CGSize(width: 390, height: ceil(fitted.height))
        window.frame = CGRect(origin: .zero, size: size)
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()

        let horizontallyScrollableCodeBlocks = descendants(of: UIScrollView.self, in: host.view)
            .filter { $0.contentSize.width > $0.bounds.width + 1 }
        XCTAssertFalse(
            horizontallyScrollableCodeBlocks.isEmpty,
            "A code block with one long line must have horizontal scrollable overflow"
        )

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
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

    @MainActor
    func testFailedStatusControlKeepsTheBubbleCompactAndVisible() throws {
        let message = Message(
            id: "failed-visual",
            content: "Could not send this message",
            isFromMe: true,
            deliveryStatus: .failed
        )
        let bubble = MessageBubble(message: message, onShowDeliveryFailure: {})
            .frame(width: 390)
            .padding()
            .background(Color.black)
        let host = UIHostingController(rootView: bubble)
        let fitted = host.sizeThatFits(in: CGSize(width: 422, height: 500))

        XCTAssertGreaterThanOrEqual(fitted.height, 80)
        XCTAssertLessThan(fitted.height, 180)

        let renderer = ImageRenderer(content: bubble)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "failed-message-status-control"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
    func testIdenticalTimelineUpdatesPreserveViewportWithoutReloading() throws {
        let controller = MessageTimelineViewController()
        controller.loadViewIfNeeded()
        controller.setViewportForTesting(CGSize(width: 390, height: 500))
        let messages = (0..<50).map { index in
            Message(
                id: "message-\(index)",
                content: String(repeating: "Variable-height message \(index). ", count: index % 5 + 1),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                isFromMe: index.isMultiple(of: 2),
                deliveryStatus: .delivered
            )
        }
        controller.update(
            messages: messages,
            messageTextScale: 1.0,
            isLoadingMore: false,
            allMessagesLoaded: true
        )
        controller.setContentOffsetForTesting(y: 1_000)

        let initialViewport = try XCTUnwrap(controller.viewportSnapshotForTesting())
        let initialReloadCount = controller.timelineReloadCountForTesting

        for _ in 0..<10 {
            controller.update(
                messages: messages,
                messageTextScale: 1.0,
                isLoadingMore: false,
                allMessagesLoaded: true
            )
        }

        let finalViewport = try XCTUnwrap(controller.viewportSnapshotForTesting())
        XCTAssertEqual(finalViewport.anchorMessageID, initialViewport.anchorMessageID)
        XCTAssertEqual(finalViewport.anchorViewportMinY, initialViewport.anchorViewportMinY, accuracy: 0.001)
        XCTAssertEqual(finalViewport.contentOffsetY, initialViewport.contentOffsetY, accuracy: 0.001)
        XCTAssertEqual(
            controller.timelineReloadCountForTesting,
            initialReloadCount,
            "An unchanged SwiftUI update must not reload or restore the collection timeline"
        )

        controller.update(
            messages: messages,
            messageTextScale: 1.0,
            isLoadingMore: true,
            allMessagesLoaded: false
        )
        XCTAssertTrue(controller.configuredLoadingState.isLoadingMore)
        XCTAssertFalse(controller.configuredLoadingState.allMessagesLoaded)
        XCTAssertEqual(controller.timelineReloadCountForTesting, initialReloadCount)

        var changedMessages = messages
        changedMessages[20].content = "Updated delivery content"
        controller.update(
            messages: changedMessages,
            messageTextScale: 1.0,
            isLoadingMore: false,
            allMessagesLoaded: true
        )
        XCTAssertEqual(controller.timelineReloadCountForTesting, initialReloadCount + 1)

        controller.update(
            messages: changedMessages,
            messageTextScale: 1.3,
            isLoadingMore: false,
            allMessagesLoaded: true
        )
        XCTAssertEqual(controller.timelineReloadCountForTesting, initialReloadCount + 2)

        controller.update(
            conversationID: "different-conversation",
            messages: changedMessages,
            messageTextScale: 1.3,
            isLoadingMore: false,
            allMessagesLoaded: true
        )
        XCTAssertEqual(controller.timelineReloadCountForTesting, initialReloadCount + 3)
    }

    @MainActor
    func testConversationTransitionPositionsNewTimelineAtBottomWithoutRestoringOldViewport() throws {
        let controller = MessageTimelineViewController()
        controller.loadViewIfNeeded()
        controller.setViewportForTesting(CGSize(width: 390, height: 500))
        let messagesA = timelineMessages(prefix: "a", count: 60)
        let messagesB = timelineMessages(prefix: "b", count: 60)

        controller.update(
            conversationID: "conversation-a",
            messages: messagesA,
            isLoadingMore: false,
            allMessagesLoaded: true
        )
        controller.setContentOffsetForTesting(y: 1_000)
        let oldViewport = try XCTUnwrap(controller.viewportSnapshotForTesting())
        XCTAssertTrue(oldViewport.anchorMessageID.hasPrefix("a-"))
        XCTAssertFalse(controller.isViewportNearBottomForTesting)

        controller.update(
            conversationID: "conversation-b",
            messages: messagesB,
            isLoadingMore: false,
            allMessagesLoaded: true
        )

        let newViewport = try XCTUnwrap(controller.viewportSnapshotForTesting())
        XCTAssertTrue(newViewport.anchorMessageID.hasPrefix("b-"))
        XCTAssertTrue(
            controller.isViewportNearBottomForTesting,
            "A reused controller must initially position the new conversation at its bottom"
        )
        XCTAssertGreaterThan(
            newViewport.contentOffsetY,
            oldViewport.contentOffsetY + 500,
            "The new conversation must not inherit the old conversation's numeric offset"
        )
    }

    @MainActor
    func testConversationTransitionCancelsOlderHistoryLoadAndRejectsItsCompletion() async {
        let gate = TimelineLoadGate()
        let oldLoadReturned = expectation(description: "old load callback returned")
        let controller = MessageTimelineViewController()
        controller.onLoadOlder = {
            await gate.wait()
            oldLoadReturned.fulfill()
            return true
        }
        controller.loadViewIfNeeded()
        controller.setViewportForTesting(CGSize(width: 390, height: 500))
        controller.update(
            conversationID: "conversation-a",
            messages: timelineMessages(prefix: "a", count: 60),
            isLoadingMore: false,
            allMessagesLoaded: false
        )
        controller.setContentOffsetForTesting(y: 0)
        await gate.waitUntilBlocked()
        XCTAssertTrue(controller.hasActiveLoadTaskForTesting)

        var newConversationLoadCount = 0
        controller.onLoadOlder = {
            newConversationLoadCount += 1
            return false
        }
        controller.update(
            conversationID: "conversation-b",
            messages: timelineMessages(prefix: "b", count: 60),
            isLoadingMore: false,
            allMessagesLoaded: false
        )

        XCTAssertFalse(
            controller.hasActiveLoadTaskForTesting,
            "Conversation B must not remain owned by conversation A's pagination task"
        )
        XCTAssertFalse(controller.configuredLoadingState.isLoadingMore)
        XCTAssertNotNil(controller.viewportSnapshotForTesting())
        XCTAssertTrue(controller.isViewportNearBottomForTesting)

        controller.update(
            conversationID: "conversation-b",
            messages: timelineMessages(prefix: "b", count: 60),
            isLoadingMore: true,
            allMessagesLoaded: false
        )
        await gate.open()
        await fulfillment(of: [oldLoadReturned], timeout: 1)
        await Task.yield()

        XCTAssertTrue(
            controller.configuredLoadingState.isLoadingMore,
            "A stale completion must not clear conversation B's externally owned loading state"
        )
        XCTAssertEqual(newConversationLoadCount, 0)
    }

    @MainActor
    func testNoOpTimelineUpdateUsesFreshPaginationCallbackWithoutReloading() async {
        let controller = MessageTimelineViewController()
        var staleCallbackCount = 0
        controller.onLoadOlder = {
            staleCallbackCount += 1
            return false
        }
        controller.loadViewIfNeeded()
        controller.setViewportForTesting(CGSize(width: 390, height: 500))
        let messages = timelineMessages(prefix: "callback", count: 60)
        controller.update(
            conversationID: "conversation",
            messages: messages,
            isLoadingMore: false,
            allMessagesLoaded: true
        )
        controller.setContentOffsetForTesting(y: 2_000)
        let reloadCount = controller.timelineReloadCountForTesting

        let freshCallbackCalled = expectation(description: "fresh pagination callback called")
        controller.onLoadOlder = {
            freshCallbackCalled.fulfill()
            return false
        }
        controller.update(
            conversationID: "conversation",
            messages: messages,
            isLoadingMore: false,
            allMessagesLoaded: false
        )
        XCTAssertEqual(controller.timelineReloadCountForTesting, reloadCount)

        controller.setContentOffsetForTesting(y: 0)
        await fulfillment(of: [freshCallbackCalled], timeout: 1)
        XCTAssertEqual(staleCallbackCount, 0)
        XCTAssertEqual(controller.timelineReloadCountForTesting, reloadCount)
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

    private func timelineMessages(prefix: String, count: Int) -> [Message] {
        (0..<count).map { index in
            Message(
                id: "\(prefix)-\(index)",
                content: String(repeating: "Variable timeline row \(prefix)-\(index). ", count: index % 5 + 1),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                isFromMe: index.isMultiple(of: 2),
                deliveryStatus: .delivered
            )
        }
    }
}

private actor TimelineLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
