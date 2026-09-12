import XCTest
@testable import ColumbaApp
import RNSAPI
import GRDB

/// Reply-quote wire parity with Android / the upstream LXMF reference.
///
/// Upstream LXMF (`reticulum/lxmf/LXMF/LXMF.py`):
///   `FIELD_REPLY_TO    = 0x30`  # Bytes, full LXMessage.hash
///   `FIELD_REPLY_QUOTE = 0x31`  # Bytes, quoted content in UTF-8 encoding
///
/// The canonical reply wire field is the target HASH (0x30). The quoted
/// content (0x31) is an *optional* interop payload carried inline so a
/// recipient can render a quote without the original in their local store
/// (MeshChatX interop; peer history aged out).
///
/// Parity contract: Android ships the FULL quoted content in 0x31
/// (`MessagingViewModel.kt` passes `getMessageById(id)?.content?.takeIf {
/// it.isNotEmpty() }` — no cap). iOS previously shipped only the first 80
/// characters (the same `prefix(80)` it uses for its local preview), so an
/// iOS→Android / iOS→MeshChatX reply delivered a quote that was silently
/// truncated mid-sentence. This pins the wire field to the full original
/// content, matching the other side.
///
/// The 80-char cap remains correct for the *display* preview (the accent-bar
/// quote above the bubble, which is `lineLimit(2)`); only the wire field is
/// changed.
@MainActor
final class ReplyQuoteParityTests: XCTestCase {
    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-reply-quote-parity-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(atPath: url.path + "-wal")
        try? fm.removeItem(atPath: url.path + "-shm")
    }

    /// A reply to a message longer than the 80-char preview cap must put the
    /// FULL original content on the wire (field 0x31), byte-for-byte, not a
    /// truncated prefix.
    func testReplyQuoteShipsFullContentOnTheWire() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x41, count: 16)

        // The original message the reply is quoting: 200 chars, well past the
        // 80-char display-preview cap.
        // 100 chars: clearly longer than the 80-char preview cap, so a cap applied
        // to the wire quote would be observable here.
        let originalContent = String(repeating: "abcdefghij", count: 10)
        XCTAssertEqual(100, originalContent.count)
        let originalID = String(repeating: "ab", count: 32)

        let captured = LockedBox<MessagingViewModel.OutboundSendRequest>(nil)
        let optimisticPreview = LockedBox<String?>(nil)
        let vmRef = LockedBox<MessagingViewModel>(nil)
        let viewModel = MessagingViewModel(
            conversationHash: destination,
            repository: repository,
            appServices: AppServices(),
            identity: Identity(),
            outboundSendOperation: { request in
                captured.value = request
                // The seam runs after the optimistic row is appended and before
                // it is replaced post-send — snapshot the display preview here.
                if let vm = vmRef.value {
                    optimisticPreview.value = vm.messages.last(where: { $0.isFromMe })?.replyToPreview
                }
                return .queued(messageHash: String(repeating: "cd", count: 32))
            }
        )
        vmRef.value = viewModel

        // Seed the replied-to message so the reply-preview lookup can resolve it.
        viewModel.messages = [
            Message(
                id: originalID,
                content: originalContent,
                isFromMe: false
            )
        ]

        let accepted = await viewModel.sendMessage(
            text: "This is my reply.",
            imageData: nil,
            imageFormat: nil,
            attachments: nil,
            replyToId: originalID
        )
        XCTAssertTrue(accepted)

        let request = try XCTUnwrap(captured.value, "the send must reach the outbound seam")
        // The reply-target hash (field 0x30) is the canonical, always-present field.
        XCTAssertEqual(originalID, request.replyToMessageHashHex)
        // The quoted content (field 0x31) must be the FULL original — not the
        // 80-char preview. This is the Android/MeshChatX parity guarantee.
        XCTAssertEqual(originalContent, request.replyQuotedContent)

        // The seam above returns before encoding runs, so assert the wire
        // contract itself: feed the captured request's reply fields through the
        // same codec both backends use and check the emitted field map.
        let wireFields = LxmfFieldCodec.buildFieldMap(
            imageData: request.imageData,
            imageFormat: request.imageFormat,
            fileAttachments: request.fileAttachments,
            audioAttachment: request.audioAttachment,
            iconAppearance: request.iconAppearance,
            replyToMessageHashHex: request.replyToMessageHashHex,
            replyQuotedContent: request.replyQuotedContent,
            extraFields: request.extraFields
        )
        let quoteField = try XCTUnwrap(
            wireFields[LxmfFields.FIELD_REPLY_QUOTE] as? Data,
            "codec must emit FIELD_REPLY_QUOTE (0x31) for a reply with local quote content"
        )
        // Full content on the wire — byte-for-byte, no cap.
        XCTAssertEqual(originalContent, String(data: quoteField, encoding: .utf8))
        let hashField = try XCTUnwrap(
            wireFields[LxmfFields.FIELD_REPLY_HASH] as? Data,
            "codec must emit FIELD_REPLY_HASH (0x30)"
        )
        XCTAssertEqual(Data(repeating: 0xab, count: 32), hashField)

        // The display-side preview must stay capped at 80 chars — the fix splits
        // the two consumers, and this pins the display half (snapshotted from the
        // optimistic row inside the seam, before the row is replaced post-send).
        XCTAssertEqual(String(originalContent.prefix(80)), optimisticPreview.value)
    }

    /// A reply to a message within the preview cap is unaffected: the quote is
    /// exactly the original content (no cap to observe at this length).
    func testReplyQuoteForShortMessageIsUnchanged() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x41, count: 16)

        let originalContent = "short quoted line"
        let originalID = String(repeating: "5f", count: 32)

        let captured = LockedBox<MessagingViewModel.OutboundSendRequest>(nil)
        let viewModel = MessagingViewModel(
            conversationHash: destination,
            repository: repository,
            appServices: AppServices(),
            identity: Identity(),
            outboundSendOperation: { request in
                captured.value = request
                return .queued(messageHash: String(repeating: "cd", count: 32))
            }
        )
        viewModel.messages = [Message(id: originalID, content: originalContent, isFromMe: false)]

        let accepted = await viewModel.sendMessage(
            text: "reply",
            imageData: nil,
            imageFormat: nil,
            attachments: nil,
            replyToId: originalID
        )
        XCTAssertTrue(accepted)

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(originalContent, request.replyQuotedContent)
    }
}

/// Minimal thread-confined box for capturing a value from an escaping closure
/// on the main actor without a heavyweight actor.
@MainActor
final class LockedBox<T> {
    var value: T?
    init(_ initial: T?) { self.value = initial }
}
