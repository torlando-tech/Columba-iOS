import XCTest
@testable import RNSAPI

/// Regression tests for the iOS image / attachment / icon-appearance LXMF
/// field paths.
///
/// Backstory: through the field-path migration the iOS Compat `LXMessage.pack()`
/// and `unpackFromBytes` stayed as stubs (returning empty `Data` / an empty
/// `LXMessage`). That made `MessageRecord.packedLxmf` *always* empty on disk —
/// so even though FIELD_IMAGE (`0x06`) survived the wire ⇄ `LxmfFieldCodec`
/// round-trip in memory, every reload from SQLite dropped the image bytes and
/// the bubble rendered without a picture. Same fate for FIELD_FILE_ATTACHMENTS
/// (`0x05`) and FIELD_ICON_APPEARANCE (`0x04`).
///
/// The fix replaces the stub-based persistence with `LxmfFieldCodec.pack` of
/// the field map into `packedLxmf`, with `LxmfFieldCodec.unpack` on the read
/// side; and implements the previously-stubbed `IconAppearance` field codec
/// (`[name, fg_rgb_bytes, bg_rgb_bytes]` per Sideband canonical wire).
///
/// These tests pin the canonical wire shapes the rest of the mesh expects
/// (Sideband upstream, Android Columba, LXMF-kt's interop tests) so future
/// edits can't silently regress interop.
///
/// Lives in the RNSAPI SwiftPM test target — no ColumbaApp/UIKit/Python deps,
/// runs with `swift test` natively.
final class AttachmentFieldRoundTripTests: XCTestCase {

    // MARK: - FIELD_IMAGE (0x06) = [format, bytes]

    /// In-memory `buildFieldMap` ⇄ `pack` ⇄ `unpack` round-trip preserves
    /// image format + bytes exactly. This is what both the Swift backend
    /// (LXMF-swift's `convertArrayToMsgpack`) and the Python backend (msgpack
    /// → hex → Python → upstream LXMF) ultimately encode, so the codec is the
    /// single point that needs to be lossless.
    func testImageFieldRoundTripLossless() throws {
        let imageBytes = Data((0..<256).map { UInt8($0) })
        let fields = LxmfFieldCodec.buildFieldMap(
            imageData: imageBytes, imageFormat: "jpeg",
            fileAttachments: nil, iconAppearance: nil,
            replyToMessageHashHex: nil, replyQuotedContent: nil,
            extraFields: nil
        )

        let packed = LxmfFieldCodec.pack(fields)
        XCTAssertFalse(packed.isEmpty, "Packing a non-empty field map should yield non-empty data")

        let unpacked = try XCTUnwrap(LxmfFieldCodec.unpack(packed))
        let imageField = try XCTUnwrap(unpacked[LxmfFields.FIELD_IMAGE] as? [Any])
        XCTAssertEqual(imageField.count, 2, "FIELD_IMAGE wire shape is [format, bytes]")
        XCTAssertEqual(imageField[0] as? String, "jpeg")
        XCTAssertEqual(imageField[1] as? Data, imageBytes)
    }

    /// The receive parser must accept *either* a `String` or UTF-8 `Data` for
    /// the format slot, because peers vary: Swift / Sideband-Python send a
    /// msgpack string, but LXMF-kt's canonical encoding uses
    /// `extension.toByteArray(Charsets.UTF_8)` which arrives as msgpack
    /// binary. Both must decode to the same `imageFormat` on iOS.
    func testImageFieldFormatAcceptsBytes() throws {
        // Build the wire form LXMF-kt would produce: [bytes, bytes]
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic
        let fields: [UInt8: Any] = [
            LxmfFields.FIELD_IMAGE: [Data("png".utf8), imageBytes] as [Any]
        ]
        let packed = LxmfFieldCodec.pack(fields)
        let unpacked = try XCTUnwrap(LxmfFieldCodec.unpack(packed))
        let imageField = try XCTUnwrap(unpacked[LxmfFields.FIELD_IMAGE] as? [Any])
        // The codec preserves binary as Data, the receive-side adapter
        // (MessageBubble.init(from record:)) decodes either form to String.
        XCTAssertEqual(imageField[0] as? Data, Data("png".utf8))
        XCTAssertEqual(imageField[1] as? Data, imageBytes)
    }

    /// Realistic Sideband-style payload: ~10 KB of pseudo-random bytes
    /// stays byte-identical after a full pack/unpack cycle. Smoke-tests
    /// MessagePack `bin8`/`bin16`/`bin32` length-prefix selection, which can
    /// regress quietly if an encoder picks the wrong size class.
    func testImageFieldLargePayloadByteIdentical() throws {
        var rng = SystemRandomNumberGenerator()
        let imageBytes = Data((0..<10_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let fields = LxmfFieldCodec.buildFieldMap(
            imageData: imageBytes, imageFormat: "webp",
            fileAttachments: nil, iconAppearance: nil,
            replyToMessageHashHex: nil, replyQuotedContent: nil,
            extraFields: nil
        )
        let unpacked = try XCTUnwrap(LxmfFieldCodec.unpack(LxmfFieldCodec.pack(fields)))
        let imageField = try XCTUnwrap(unpacked[LxmfFields.FIELD_IMAGE] as? [Any])
        XCTAssertEqual(imageField[1] as? Data, imageBytes)
        XCTAssertEqual((imageField[1] as? Data)?.count, 10_000)
    }

    // MARK: - FIELD_FILE_ATTACHMENTS (0x05) = [[name, bytes], …]

    /// Multi-file attachment array round-trips. The wire shape is a list of
    /// `[name_str, bytes]` pairs (matching Sideband's `[(name, content), …]`
    /// canonical form), and the codec / Compat parser need to preserve all
    /// of them.
    func testFileAttachmentsRoundTripMultiple() throws {
        let a = RnsFileAttachment(name: "note.txt", data: Data("hello".utf8))
        let b = RnsFileAttachment(name: "log.bin", data: Data([0x00, 0xFF, 0x42]))
        let fields = LxmfFieldCodec.buildFieldMap(
            imageData: nil, imageFormat: nil,
            fileAttachments: [a, b],
            iconAppearance: nil,
            replyToMessageHashHex: nil, replyQuotedContent: nil,
            extraFields: nil
        )
        let unpacked = try XCTUnwrap(LxmfFieldCodec.unpack(LxmfFieldCodec.pack(fields)))
        let files = try XCTUnwrap(unpacked[LxmfFields.FIELD_FILE_ATTACHMENTS] as? [Any])
        XCTAssertEqual(files.count, 2)

        let first = try XCTUnwrap(files[0] as? [Any])
        XCTAssertEqual(first[0] as? String, "note.txt")
        XCTAssertEqual(first[1] as? Data, Data("hello".utf8))

        let second = try XCTUnwrap(files[1] as? [Any])
        XCTAssertEqual(second[0] as? String, "log.bin")
        XCTAssertEqual(second[1] as? Data, Data([0x00, 0xFF, 0x42]))
    }

    // MARK: - FIELD_ICON_APPEARANCE (0x04) = [name, fg_rgb_bytes, bg_rgb_bytes]

    /// `IconAppearance` ⇄ `[Any]` wire form round-trips. Previously
    /// `toLXMFFieldValue()` was a `Data()` stub and `fromLXMFFieldValue` was
    /// `nil`, so iOS sent empty icons and never parsed inbound icons — the
    /// 🔴 gap called out in the dual-backend architecture doc.
    func testIconAppearanceRoundTrip() throws {
        let icon = IconAppearance(iconName: "owl", fgColor: "ff8800", bgColor: "112233")
        let fieldValue = icon.toLXMFFieldValue()

        // Pin the in-memory wire shape: [String, Data(3), Data(3)] — what the
        // msgpack encoder (both LxmfFieldCodec.value(fromAny:) and LXMF-swift's
        // convertArrayToMsgpack) sees before producing .array([.string,
        // .binary, .binary]) on the wire.
        XCTAssertEqual(fieldValue.count, 3)
        XCTAssertEqual(fieldValue[0] as? String, "owl")
        XCTAssertEqual(fieldValue[1] as? Data, Data([0xFF, 0x88, 0x00]))
        XCTAssertEqual(fieldValue[2] as? Data, Data([0x11, 0x22, 0x33]))

        // Full round-trip back through fromLXMFFieldValue must reconstruct
        // the original (modulo lowercase hex normalisation).
        let restored = try XCTUnwrap(IconAppearance.fromLXMFFieldValue(fieldValue))
        XCTAssertEqual(restored.iconName, "owl")
        XCTAssertEqual(restored.fgColor, "ff8800")
        XCTAssertEqual(restored.bgColor, "112233")
    }

    /// Through the full msgpack pack ⇄ unpack cycle, including the
    /// dual-form name handling (string vs UTF-8 bytes).
    func testIconAppearanceMsgPackRoundTrip() throws {
        let icon = IconAppearance(iconName: "leaf", fgColor: "00ff00", bgColor: "ffffff")
        let fields: [UInt8: Any] = [LxmfFields.FIELD_ICON_APPEARANCE: icon.toLXMFFieldValue()]
        let unpacked = try XCTUnwrap(LxmfFieldCodec.unpack(LxmfFieldCodec.pack(fields)))
        let value = try XCTUnwrap(unpacked[LxmfFields.FIELD_ICON_APPEARANCE])
        let restored = try XCTUnwrap(IconAppearance.fromLXMFFieldValue(value))
        XCTAssertEqual(restored, icon)
    }

    /// LXMF-kt's canonical wire encodes the icon name as UTF-8 bytes — the
    /// parser must accept that too (mirrors `testImageFieldFormatAcceptsBytes`).
    func testIconAppearanceParsesUTF8NameBytes() throws {
        // Simulate LXMF-kt's wire form: [Data, Data(3), Data(3)].
        let wireValue: [Any] = [
            Data("crow".utf8),
            Data([0xAB, 0xCD, 0xEF]),
            Data([0x12, 0x34, 0x56]),
        ]
        let restored = try XCTUnwrap(IconAppearance.fromLXMFFieldValue(wireValue))
        XCTAssertEqual(restored.iconName, "crow")
        XCTAssertEqual(restored.fgColor, "abcdef")
        XCTAssertEqual(restored.bgColor, "123456")
    }

    /// CSS-style `#RRGGBB` is accepted on encode (some pickers store with the
    /// leading `#`); decode normalises to plain 6-char lowercase hex (the
    /// `ProfileIcon` storage form).
    func testIconAppearanceAcceptsHashPrefixOnEncode() throws {
        let icon = IconAppearance(iconName: "fox", fgColor: "#FF8800", bgColor: "#112233")
        let value = icon.toLXMFFieldValue()
        XCTAssertEqual(value[1] as? Data, Data([0xFF, 0x88, 0x00]))
        XCTAssertEqual(value[2] as? Data, Data([0x11, 0x22, 0x33]))
    }

    /// Malformed inputs (wrong arity, wrong byte count, empty name) return
    /// nil rather than crashing or returning garbage — IncomingMessageHandler
    /// relies on `nil` to mean "skip the peer-icon update".
    func testIconAppearanceFromMalformedReturnsNil() {
        // Wrong arity
        XCTAssertNil(IconAppearance.fromLXMFFieldValue(["owl"] as [Any]))
        XCTAssertNil(IconAppearance.fromLXMFFieldValue(["owl", Data([0xFF, 0x88, 0x00])] as [Any]))

        // Wrong colour byte count
        XCTAssertNil(IconAppearance.fromLXMFFieldValue([
            "owl", Data([0xFF, 0x88]), Data([0x11, 0x22, 0x33])
        ] as [Any]))

        // Empty name
        XCTAssertNil(IconAppearance.fromLXMFFieldValue([
            "", Data([0xFF, 0x88, 0x00]), Data([0x11, 0x22, 0x33])
        ] as [Any]))

        // Non-array input
        XCTAssertNil(IconAppearance.fromLXMFFieldValue("not-an-array"))
    }

    // MARK: - Empty + nil edge cases

    /// `buildFieldMap` with no arguments returns an empty map, which
    /// `pack` represents as empty `Data()`, and `unpack` of empty data
    /// returns nil. This is the contract `Compat.saveMessage` relies on
    /// — empty fields → empty `packedLxmf` (rather than an empty msgpack
    /// map byte) so cold-loaded records that never had fields produce
    /// `nil` (not a non-nil empty dict) from `unpack`.
    func testEmptyFieldMapProducesEmptyPackedAndNilUnpack() {
        let empty = LxmfFieldCodec.buildFieldMap(
            imageData: nil, imageFormat: nil,
            fileAttachments: nil, iconAppearance: nil,
            replyToMessageHashHex: nil, replyQuotedContent: nil,
            extraFields: nil
        )
        XCTAssertTrue(empty.isEmpty)

        let packed = LxmfFieldCodec.pack(empty)
        XCTAssertTrue(packed.isEmpty, "Empty field map must pack to empty Data so callers can treat it as `no fields`")

        XCTAssertNil(LxmfFieldCodec.unpack(packed))
        XCTAssertNil(LxmfFieldCodec.unpack(Data()))
    }
}

/// Integration tests against the real `LXMFDatabase` SQLite store, verifying
/// that fields persist round-trip through `saveMessage(...)` → in-memory
/// cache → `getMessageRecord(id:)` and survive what the UI does on reload.
///
/// Until the fix below `LXMessage.pack()`/`unpackFromBytes` are stubs, so the
/// old saveMessage code stored an empty `packedLxmf` and every reload dropped
/// image / attachment / icon payloads. These tests pin that path closed.
final class LXMFDatabaseFieldPersistenceTests: XCTestCase {

    private var tmpDBPath: String!

    override func setUp() {
        super.setUp()
        let tmpDir = NSTemporaryDirectory()
        tmpDBPath = (tmpDir as NSString).appendingPathComponent("lxmf-test-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        if let path = tmpDBPath { try? FileManager.default.removeItem(atPath: path) }
        super.tearDown()
    }

    /// Saving an LXMessage with `FIELD_IMAGE` survives the in-memory + on-disk
    /// round-trip. This is the regression the user reported: "I tested image
    /// attachments; they aren't sending correctly, and received image
    /// attachments don't load" — both halves trace back to `saveMessage`
    /// dropping `message.fields` because `packedLxmf` defaulted to empty.
    func testSaveMessagePersistsImageFieldThroughDatabase() throws {
        let db = LXMFDatabase(path: tmpDBPath)

        let imageBytes = Data((0..<512).map { UInt8($0 & 0xFF) })
        let messageHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let sourceHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        let message = LXMessage(
            destinationHash: sourceHash,
            sourceIdentity: nil,
            content: Data("here's the photo".utf8),
            title: Data(),
            fields: [LXMessage.FIELD_IMAGE: ["jpeg", imageBytes] as [Any]],
            desiredMethod: .opportunistic
        )
        message.hash = messageHash
        message.sourceHash = sourceHash
        message.incoming = true
        message.state = .received

        try db.saveMessage(message)

        let record = try XCTUnwrap(try db.getMessageRecord(id: messageHash))
        XCTAssertFalse(record.packedLxmf.isEmpty,
                       "saveMessage must populate packedLxmf with the encoded field map")

        let unpacked = try XCTUnwrap(LxmfFieldCodec.unpack(record.packedLxmf))
        let imageField = try XCTUnwrap(unpacked[LXMessage.FIELD_IMAGE] as? [Any])
        XCTAssertEqual(imageField[0] as? String, "jpeg")
        XCTAssertEqual(imageField[1] as? Data, imageBytes)
    }

    /// A message without fields persists with empty `packedLxmf` (rather than
    /// an empty-but-non-zero msgpack map) so a downstream `LxmfFieldCodec.unpack`
    /// cleanly returns nil — the contract MessageBubble depends on.
    func testSaveMessageWithoutFieldsLeavesPackedLxmfEmpty() throws {
        let db = LXMFDatabase(path: tmpDBPath)
        let messageHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let message = LXMessage(
            destinationHash: Data(repeating: 0x01, count: 16),
            sourceIdentity: nil,
            content: Data("text only".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .opportunistic
        )
        message.hash = messageHash
        message.sourceHash = Data(repeating: 0x02, count: 16)
        message.state = .sent

        try db.saveMessage(message)
        let record = try XCTUnwrap(try db.getMessageRecord(id: messageHash))
        XCTAssertTrue(record.packedLxmf.isEmpty)
        XCTAssertNil(LxmfFieldCodec.unpack(record.packedLxmf))
    }

    /// Combined attachment + icon + reply payload survives the persistence
    /// cycle as a unit — the realistic shape of a chat message that carries
    /// multiple fields at once.
    func testSaveMessagePersistsMultipleFields() throws {
        let db = LXMFDatabase(path: tmpDBPath)

        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let attachmentBytes = Data("file contents".utf8)
        let replyHash = Data((0..<32).map { UInt8($0) })
        let messageHash = Data(repeating: 0xAA, count: 32)

        let icon = IconAppearance(iconName: "owl", fgColor: "ff8800", bgColor: "112233")
        let fields: [UInt8: Any] = [
            LXMessage.FIELD_IMAGE: ["png", imageBytes] as [Any],
            LxmfFields.FIELD_FILE_ATTACHMENTS: [["doc.txt", attachmentBytes] as [Any]] as [Any],
            LxmfFields.FIELD_ICON_APPEARANCE: icon.toLXMFFieldValue(),
            LxmfFields.FIELD_REPLY_HASH: replyHash,
        ]
        let message = LXMessage(
            destinationHash: Data(repeating: 0x01, count: 16),
            sourceIdentity: nil,
            content: Data("with attachments".utf8),
            title: Data(),
            fields: fields,
            desiredMethod: .opportunistic
        )
        message.hash = messageHash
        message.sourceHash = Data(repeating: 0x03, count: 16)

        try db.saveMessage(message)
        let record = try XCTUnwrap(try db.getMessageRecord(id: messageHash))
        let unpacked = try XCTUnwrap(LxmfFieldCodec.unpack(record.packedLxmf))

        // Image
        let imageField = try XCTUnwrap(unpacked[LXMessage.FIELD_IMAGE] as? [Any])
        XCTAssertEqual(imageField[0] as? String, "png")
        XCTAssertEqual(imageField[1] as? Data, imageBytes)

        // Files
        let filesField = try XCTUnwrap(unpacked[LxmfFields.FIELD_FILE_ATTACHMENTS] as? [Any])
        let firstFile = try XCTUnwrap(filesField[0] as? [Any])
        XCTAssertEqual(firstFile[0] as? String, "doc.txt")
        XCTAssertEqual(firstFile[1] as? Data, attachmentBytes)

        // Icon (full round-trip including fromLXMFFieldValue)
        let iconValue = try XCTUnwrap(unpacked[LxmfFields.FIELD_ICON_APPEARANCE])
        XCTAssertEqual(IconAppearance.fromLXMFFieldValue(iconValue), icon)

        // Reply hash
        XCTAssertEqual(unpacked[LxmfFields.FIELD_REPLY_HASH] as? Data, replyHash)
    }
}
