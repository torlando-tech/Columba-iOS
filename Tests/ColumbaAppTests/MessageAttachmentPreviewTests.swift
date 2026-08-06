import XCTest
import UIKit
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

        XCTAssertEqual(item.url.pathExtension.lowercased(), "jpg")
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

final class MessageAttachmentRoutingTests: XCTestCase {
    @MainActor
    func testFileSelectionRoutesStableIndexAndFreshCallbackWithoutReload() throws {
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

        var staleIndex: Int?
        controller.onOpenFileAttachment = { _, index in staleIndex = index }
        var selected: (String, Data, Int)?
        controller.onOpenFileAttachment = { routedMessage, index in
            let attachment = routedMessage.attachments![index]
            selected = (attachment.name, attachment.data, index)
        }
        controller.update(messages: [message], isLoadingMore: false, allMessagesLoaded: true)
        controller.openFileAttachmentForTesting(messageID: message.id, index: 1)

        XCTAssertNil(staleIndex)
        XCTAssertEqual(selected?.0, "second.txt")
        XCTAssertEqual(selected?.1, Data("second".utf8))
        XCTAssertEqual(selected?.2, 1)
        XCTAssertEqual(controller.timelineReloadCountForTesting, reloadCount)
    }

    @MainActor
    func testAttachmentBubbleProducesVisualEvidenceAndTapCallbacks() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData()
        let message = Message(
            content: "Attachments",
            isFromMe: false,
            imageData: image,
            imageFormat: "png",
            attachments: [FileAttachment(name: "document.txt", data: Data("contents".utf8))]
        )
        var imageTapCount = 0
        var fileIndex: Int?
        let renderer = ImageRenderer(content:
            MessageBubble(
                message: message,
                onOpenImage: { imageTapCount += 1 },
                onOpenFileAttachment: { fileIndex = $0 }
            )
            .frame(width: 320)
            .padding()
            .background(Color.black)
        )
        renderer.scale = 3
        let screenshot = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(screenshot.size.height, 80)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "interactive-image-and-file-attachment-controls"
        attachment.lifetime = .keepAlways
        add(attachment)

        let bubble = MessageBubble(
            message: message,
            onOpenImage: { imageTapCount += 1 },
            onOpenFileAttachment: { fileIndex = $0 }
        )
        bubble.onOpenImage?()
        bubble.onOpenFileAttachment?(0)
        XCTAssertEqual(imageTapCount, 1)
        XCTAssertEqual(fileIndex, 0)
    }
}
