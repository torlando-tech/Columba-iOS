import XCTest
@testable import ColumbaApp

final class IncomingMessageSizeLimitTests: XCTestCase {
    func testIncomingMessageSizeLimitDefaultsToAndroidCompatibleValue() async {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return XCTFail("Could not create app-group UserDefaults")
        }
        defaults.removeObject(forKey: "incoming_message_size_limit_kb")
        let repo = SettingsRepository()
        let value = await repo.getIncomingMessageSizeLimitKB()
        XCTAssertEqual(value, SettingsRepository.IncomingMessageSizeLimit.defaultKB)
    }

    func testIncomingMessageSizeLimitPersistsAndClamps() async {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return XCTFail("Could not create app-group UserDefaults")
        }
        defaults.removeObject(forKey: "incoming_message_size_limit_kb")
        let repo = SettingsRepository()
        await repo.setIncomingMessageSizeLimitKB(25_600)
        XCTAssertEqual(await repo.getIncomingMessageSizeLimitKB(), 25_600)

        await repo.setIncomingMessageSizeLimitKB(1)
        XCTAssertEqual(await repo.getIncomingMessageSizeLimitKB(), SettingsRepository.IncomingMessageSizeLimit.minimumKB)

        await repo.setIncomingMessageSizeLimitKB(500_000)
        XCTAssertEqual(await repo.getIncomingMessageSizeLimitKB(), SettingsRepository.IncomingMessageSizeLimit.unlimitedKB)
    }

    func testIncomingMessageSizeLimitRepairsMalformedStoredValues() async {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return XCTFail("Could not create app-group UserDefaults")
        }
        defer {
            defaults.removeObject(forKey: "incoming_message_size_limit_kb")
        }

        defaults.set(-7, forKey: "incoming_message_size_limit_kb")
        let repo = SettingsRepository()
        XCTAssertEqual(await repo.getIncomingMessageSizeLimitKB(), SettingsRepository.IncomingMessageSizeLimit.minimumKB)

        defaults.set("not-a-number", forKey: "incoming_message_size_limit_kb")
        XCTAssertEqual(await repo.getIncomingMessageSizeLimitKB(), SettingsRepository.IncomingMessageSizeLimit.defaultKB)
    }
}
