import XCTest
import UIKit
import SwiftUI
@testable import ColumbaApp

final class MessageAttachmentPreviewItemTests: XCTestCase {
    private let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL1WQAAAABJRU5ErkJggg==")!

    func testExportPreservesOriginalBytesAndDetectedTypeBeatsDeclaration() throws {
        let item = try MessageAttachmentPreviewItem(
            data: pngData,
            suggestedFilename: "photo.jpg",
            declaredImageFormat: "jpeg",
            isImage: true
        )
        defer { item.cleanup() }

        XCTAssertEqual(try Data(contentsOf: item.url), pngData)
        XCTAssertEqual(item.url.pathExtension.lowercased(), "png")
    }

    func testImageTypeDetectionDoesNotRequireDeclaredFormat() throws {
        let item = try MessageAttachmentPreviewItem(
            data: pngData,
            suggestedFilename: "image",
            isImage: true
        )
        defer { item.cleanup() }

        XCTAssertEqual(item.url.pathExtension.lowercased(), "png")
        XCTAssertEqual(try Data(contentsOf: item.url), pngData)
    }

    func testMimeTypeDeclarationProvidesImageExtensionWhenBytesAreUnknown() throws {
        let bytes = Data("not a decodable image".utf8)
        let item = try MessageAttachmentPreviewItem(
            data: bytes,
            suggestedFilename: "image",
            declaredImageFormat: "image/jpeg",
            isImage: true
        )
        defer { item.cleanup() }

        XCTAssertEqual(item.url.pathExtension.lowercased(), "jpeg")
        XCTAssertEqual(try Data(contentsOf: item.url), bytes)
    }

    func testAdversarialNamesStayInsideOwnedDirectory() throws {
        let names = [
            "../../secret.txt", "..\\..\\secret.txt", "/tmp/secret.txt",
            "control\u{0000}name.txt", "", String(repeating: "x", count: 400) + ".txt",
        ]

        for name in names {
            let item = try MessageAttachmentPreviewItem(data: Data("payload".utf8), suggestedFilename: name)
            defer { item.cleanup() }
            XCTAssertEqual(item.url.deletingLastPathComponent(), item.directoryURL)
            XCTAssertFalse(item.url.lastPathComponent.isEmpty)
            XCTAssertFalse(item.url.lastPathComponent.contains("/"))
            XCTAssertFalse(item.url.lastPathComponent.contains("\\"))
            XCTAssertLessThanOrEqual(item.url.lastPathComponent.utf8.count, 120)
        }
    }

    func testDuplicateNamesAndCleanupAreItemScopedAndIdempotent() throws {
        let first = try MessageAttachmentPreviewItem(data: Data("first".utf8), suggestedFilename: "same.bin")
        let second = try MessageAttachmentPreviewItem(data: Data("second".utf8), suggestedFilename: "same.bin")
        defer { second.cleanup() }

        XCTAssertNotEqual(first.directoryURL, second.directoryURL)
        XCTAssertEqual(try Data(contentsOf: first.url), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.url), Data("second".utf8))

        first.cleanup()
        first.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }
}

@MainActor
final class MessageAttachmentPreviewStoreTests: XCTestCase {
    func testReplacementDismissalAndConversationExitCleanOnlyOwnedItems() throws {
        let sibling = try MessageAttachmentPreviewItem(
            data: Data("sibling".utf8),
            suggestedFilename: "sibling.bin"
        )
        defer { sibling.cleanup() }
        let first = try MessageAttachmentPreviewItem(
            data: Data("first".utf8),
            suggestedFilename: "first.bin"
        )
        let second = try MessageAttachmentPreviewItem(
            data: Data("second".utf8),
            suggestedFilename: "second.bin"
        )
        let third = try MessageAttachmentPreviewItem(
            data: Data("third".utf8),
            suggestedFilename: "third.bin"
        )
        let store = MessageAttachmentPreviewStore(item: first)

        store.present(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.url.path))

        store.dismiss()
        store.dismiss()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.url.path))

        store.present(third)
        store.exitConversation()
        store.exitConversation()
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.url.path))
    }
}

final class MessageAttachmentRoutingTests: XCTestCase {
    @MainActor
    func testRepresentableRefreshesImageAndFileCallbacksWithoutReload() throws {
        let attachments = [
            FileAttachment(name: "first.txt", data: Data("first".utf8)),
            FileAttachment(name: "second.txt", data: Data("second".utf8)),
        ]
        let message = Message(id: "with-files", content: "", isFromMe: false, attachments: attachments)
        let controller = MessageTimelineViewController()
        controller.loadViewIfNeeded()
        controller.setViewportForTesting(CGSize(width: 390, height: 500))
        controller.update(messages: [message], isLoadingMore: false, allMessagesLoaded: true)
        let reloadCount = controller.timelineReloadCountForTesting

        var staleImageID: String?
        var staleFileIndex: Int?
        makeTimeline(
            message: message,
            onOpenImage: { staleImageID = $0.id },
            onOpenFile: { _, index in staleFileIndex = index }
        ).applyAttachmentCallbacks(to: controller)

        var selectedImageID: String?
        var selected: (String, Data, Int)?
        makeTimeline(
            message: message,
            onOpenImage: { selectedImageID = $0.id },
            onOpenFile: { routedMessage, index in
                let attachment = routedMessage.attachments![index]
                selected = (attachment.name, attachment.data, index)
            }
        ).applyAttachmentCallbacks(to: controller)
        controller.update(messages: [message], isLoadingMore: false, allMessagesLoaded: true)
        controller.openImageAttachmentForTesting(messageID: message.id)
        controller.openFileAttachmentForTesting(messageID: message.id, index: 1)

        XCTAssertNil(staleImageID)
        XCTAssertNil(staleFileIndex)
        XCTAssertEqual(selectedImageID, message.id)
        XCTAssertEqual(selected?.0, "second.txt")
        XCTAssertEqual(selected?.1, Data("second".utf8))
        XCTAssertEqual(selected?.2, 1)
        XCTAssertEqual(controller.timelineReloadCountForTesting, reloadCount)
    }

    @MainActor
    func testAttachmentBubbleProducesVisualEvidenceForInteractiveControls() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let message = Message(
            content: "Attachments",
            isFromMe: false,
            imageData: image,
            imageFormat: "png",
            attachments: [FileAttachment(name: "document.txt", data: Data("contents".utf8))]
        )
        let renderer = ImageRenderer(content:
            MessageBubble(
                message: message,
                onOpenImage: {},
                onOpenFileAttachment: { _ in }
            )
            .frame(width: 320)
            .padding()
            .padding(.bottom, 32)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        )
        renderer.scale = 3
        let screenshot = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(screenshot.size.height, 80)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "interactive-image-and-file-attachment-controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func makeTimeline(
        message: Message,
        onOpenImage: @escaping (Message) -> Void,
        onOpenFile: @escaping (Message, Int) -> Void
    ) -> MessageTimelineView {
        MessageTimelineView(
            conversationID: "attachment-callback-test",
            messages: [message],
            messageTextScale: 1,
            isLoadingMore: false,
            allMessagesLoaded: true,
            onLoadOlder: { false },
            onReply: { _ in },
            onToggleReaction: { _, _ in },
            onLongPress: { _ in },
            onOpenLink: { _ in },
            onOpenImage: onOpenImage,
            onOpenFileAttachment: onOpenFile
        )
    }
}
