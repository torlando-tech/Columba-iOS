import XCTest
@testable import ColumbaApp

final class IncomingMessageSizeLimitTests: XCTestCase {
    func testIncomingMessageSizeLimitDefaultsToAndroidCompatibleValue() async {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return XCTFail("Could not create app-group UserDefaults")
        }
        defaults.removeObject(forKey: "incoming_message_size_limit_kb")
        defer { defaults.removeObject(forKey: "incoming_message_size_limit_kb") }

        let repo = SettingsRepository()
        let value = await repo.getIncomingMessageSizeLimitKB()
        XCTAssertEqual(value, SettingsRepository.IncomingMessageSizeLimit.defaultKB)
    }

    func testIncomingMessageSizeLimitPersistsAndClamps() async {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return XCTFail("Could not create app-group UserDefaults")
        }
        defaults.removeObject(forKey: "incoming_message_size_limit_kb")
        defer { defaults.removeObject(forKey: "incoming_message_size_limit_kb") }

        let repo = SettingsRepository()
        await repo.setIncomingMessageSizeLimitKB(25_600)
        let persisted = await repo.getIncomingMessageSizeLimitKB()
        XCTAssertEqual(persisted, 25_600)

        await repo.setIncomingMessageSizeLimitKB(1)
        let minimum = await repo.getIncomingMessageSizeLimitKB()
        XCTAssertEqual(minimum, SettingsRepository.IncomingMessageSizeLimit.minimumKB)

        await repo.setIncomingMessageSizeLimitKB(500_000)
        let maximum = await repo.getIncomingMessageSizeLimitKB()
        XCTAssertEqual(maximum, SettingsRepository.IncomingMessageSizeLimit.unlimitedKB)
    }

    func testIncomingMessageSizeLimitRepairsMalformedStoredValues() async {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return XCTFail("Could not create app-group UserDefaults")
        }
        defaults.removeObject(forKey: "incoming_message_size_limit_kb")
        defer { defaults.removeObject(forKey: "incoming_message_size_limit_kb") }

        defaults.set(-7, forKey: "incoming_message_size_limit_kb")
        let repo = SettingsRepository()
        let minimum = await repo.getIncomingMessageSizeLimitKB()
        XCTAssertEqual(minimum, SettingsRepository.IncomingMessageSizeLimit.minimumKB)

        defaults.set("not-a-number", forKey: "incoming_message_size_limit_kb")
        let repaired = await repo.getIncomingMessageSizeLimitKB()
        XCTAssertEqual(repaired, SettingsRepository.IncomingMessageSizeLimit.defaultKB)
    }
}

final class ComposerKeyboardPreferenceTests: XCTestCase {
    private let key = "send_message_on_return"

    func testReturnKeyDefaultsToSendingMessages() {
        let suiteName = "ComposerKeyboardPreferenceTests-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ComposerKeyboardPreference.sendsOnReturn(in: defaults))
    }

    func testReturnKeyCanBeConfiguredToInsertNewlines() {
        let suiteName = "ComposerKeyboardPreferenceTests-newline-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: key)

        XCTAssertFalse(ComposerKeyboardPreference.sendsOnReturn(in: defaults))
    }

    func testOnlyUnmarkedKeyboardReturnSubmits() {
        XCTAssertTrue(ComposerReturnDecision.shouldSubmit(
            replacementText: "\n",
            sendsOnReturn: true,
            hasMarkedText: false,
            isPerformingPaste: false
        ))
        XCTAssertFalse(ComposerReturnDecision.shouldSubmit(
            replacementText: "\n",
            sendsOnReturn: true,
            hasMarkedText: false,
            isPerformingPaste: true
        ))
        XCTAssertFalse(ComposerReturnDecision.shouldSubmit(
            replacementText: "\n",
            sendsOnReturn: true,
            hasMarkedText: true,
            isPerformingPaste: false
        ))
        XCTAssertFalse(ComposerReturnDecision.shouldSubmit(
            replacementText: "\n",
            sendsOnReturn: false,
            hasMarkedText: false,
            isPerformingPaste: false
        ))
        XCTAssertFalse(ComposerReturnDecision.shouldSubmit(
            replacementText: "pasted text",
            sendsOnReturn: true,
            hasMarkedText: false,
            isPerformingPaste: false
        ))
    }
}

final class MessageTextScaleTests: XCTestCase {
    private let key = "message_text_scale"

    func testMessageTextScaleDefaultsToAndroidParityValue() async {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return XCTFail("Could not create app-group UserDefaults")
        }
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let repository = SettingsRepository()
        let value = await repository.getMessageTextScale()

        XCTAssertEqual(value, 1.0, accuracy: 0.001)
    }

    func testMessageTextScalePersistsRoundsAndClamps() async {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return XCTFail("Could not create app-group UserDefaults")
        }
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let repository = SettingsRepository()
        await repository.setMessageTextScale(1.26)
        let rounded = await repository.getMessageTextScale()
        XCTAssertEqual(rounded, 1.3, accuracy: 0.001)

        await repository.setMessageTextScale(0.1)
        let minimum = await repository.getMessageTextScale()
        XCTAssertEqual(minimum, 0.7, accuracy: 0.001)

        await repository.setMessageTextScale(9.0)
        let maximum = await repository.getMessageTextScale()
        XCTAssertEqual(maximum, 2.0, accuracy: 0.001)
    }

    func testMessageTextScaleRepairsMalformedStoredValues() async {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return XCTFail("Could not create app-group UserDefaults")
        }
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        defaults.set("not-a-number", forKey: key)
        let repository = SettingsRepository()
        let repaired = await repository.getMessageTextScale()

        XCTAssertEqual(repaired, 1.0, accuracy: 0.001)
        XCTAssertEqual(defaults.double(forKey: key), 1.0, accuracy: 0.001)
    }
}
