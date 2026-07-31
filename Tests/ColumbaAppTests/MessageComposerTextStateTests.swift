import SwiftUI
import XCTest
#if COLUMBA_RUNTIME_MODEL_B
@testable import ColumbaModelBApp
#else
@testable import ColumbaApp
#endif

@available(iOS 17.0, macOS 14.0, *)
@MainActor
final class MessageComposerTextStateTests: XCTestCase {
    func testAutocorrectionCallbackFromPreSendEditorCannotRestoreClearedText() {
        let composer = MessageComposerTextState()
        let preSendEditor = composer.binding()

        // The user types a word for which UIKit has a pending correction.
        preSendEditor.wrappedValue = "teh"
        XCTAssertEqual(composer.text, "teh")

        // Sending clears the composer and replaces the editor generation.
        composer.clearAfterSend()
        XCTAssertEqual(composer.text, "")

        // UIKit can still deliver its final corrected value through the old
        // binding. That callback must not repopulate the sent text field.
        preSendEditor.wrappedValue = "the"
        XCTAssertEqual(composer.text, "")
    }

    func testCurrentEditorStillAcceptsTextAfterSendReset() {
        let composer = MessageComposerTextState()
        let oldEditor = composer.binding()
        oldEditor.wrappedValue = "first"
        composer.clearAfterSend()

        let currentEditor = composer.binding()
        currentEditor.wrappedValue = "next message"

        XCTAssertEqual(composer.text, "next message")
    }
}
