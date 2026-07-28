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
