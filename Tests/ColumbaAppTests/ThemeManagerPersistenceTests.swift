//
//  ThemeManagerPersistenceTests.swift
//  ColumbaAppTests
//
//  Regression coverage for theme persistence across ThemeManager instances.
//

import Foundation
import SwiftUI
import XCTest
@testable import ColumbaApp

@available(iOS 17.0, macOS 14.0, *)
@MainActor
final class ThemeManagerPersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.Columba.ThemeManagerPersistence.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testColorSchemePreferenceRestoresAcrossManagerInstances() {
        do {
            let first = ThemeManager(defaults: defaults)
            first.setColorScheme(.light)
        }

        let second = ThemeManager(defaults: defaults)
        XCTAssertEqual(second.colorSchemePreference, .light)
        XCTAssertEqual(second.resolvedColorScheme, .light)
        XCTAssertFalse(second.isDarkMode)
        XCTAssertEqual(second.activeColors, PresetThemeId.plum.colors)
    }

    func testPresetSelectionRestoresPresetAndResolvedColors() {
        do {
            let first = ThemeManager(defaults: defaults)
            first.selectPreset(.ocean)
        }

        let second = ThemeManager(defaults: defaults)
        XCTAssertEqual(second.activePresetId, .ocean)
        XCTAssertNil(second.activeCustomThemeId)
        XCTAssertEqual(second.activeColors, PresetThemeId.ocean.colors)
        XCTAssertEqual(second.accentColor, Color(hex: PresetThemeId.ocean.colors.accentHex))
    }

    func testCustomThemeAndSelectionRestoreAcrossManagerInstances() {
        let custom = CustomThemeData(
            id: UUID(),
            name: "Sunlit Relay",
            primaryHue: 38,
            saturation: 0.72,
            brightness: 0.64,
            harmonized: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        do {
            let first = ThemeManager(defaults: defaults)
            first.addCustomTheme(custom)
        }

        let second = ThemeManager(defaults: defaults)
        XCTAssertEqual(second.customThemes, [custom])
        XCTAssertEqual(second.activeCustomThemeId, custom.id)
        XCTAssertNil(second.activePresetId)
        XCTAssertEqual(second.activeColors, custom.generateColors())
        XCTAssertEqual(second.accentColor, Color(hex: custom.generateColors().accentHex))
    }

    func testSelectionPersistenceKeepsPresetAndCustomIDsMutuallyExclusive() {
        let custom = CustomThemeData(id: UUID(), name: "Custom")

        do {
            let first = ThemeManager(defaults: defaults)
            first.selectPreset(.teal)
            first.addCustomTheme(custom)
            first.selectPreset(.forest)
        }

        let second = ThemeManager(defaults: defaults)
        XCTAssertEqual(second.activePresetId, .forest)
        XCTAssertNil(second.activeCustomThemeId)
        XCTAssertEqual(second.activeColors, PresetThemeId.forest.colors)
    }

    func testAggregatePresetSelectionDoesNotFallBackToStaleLegacyCustomID() {
        let custom = CustomThemeData(id: UUID(), name: "Legacy Custom")
        defaults.set(custom.id.uuidString, forKey: "theme_customThemeId")
        defaults.set(try! JSONEncoder().encode([custom]), forKey: "theme_customThemes")

        do {
            let first = ThemeManager(defaults: defaults)
            XCTAssertEqual(first.activeCustomThemeId, custom.id)
            first.selectPreset(.midnight)
        }

        let second = ThemeManager(defaults: defaults)
        XCTAssertEqual(second.activePresetId, .midnight)
        XCTAssertNil(second.activeCustomThemeId)
        XCTAssertEqual(second.activeColors, PresetThemeId.midnight.colors)
    }

    func testLegacyCustomIDWinsOverPersistedPreset() {
        let custom = CustomThemeData(id: UUID(), name: "Custom", primaryHue: 210)

        defaults.set(PresetThemeId.rose.rawValue, forKey: "theme_presetId")
        defaults.set(custom.id.uuidString, forKey: "theme_customThemeId")
        defaults.set(try! JSONEncoder().encode([custom]), forKey: "theme_customThemes")

        let customWins = ThemeManager(defaults: defaults)
        XCTAssertEqual(customWins.activeCustomThemeId, custom.id)
        XCTAssertNil(customWins.activePresetId)
        XCTAssertEqual(customWins.activeColors, custom.generateColors())
    }

    func testInvalidLegacyIDsFallBackToPlum() {
        defaults.set("not-a-preset", forKey: "theme_presetId")
        defaults.set("not-a-uuid", forKey: "theme_customThemeId")

        let invalidIDs = ThemeManager(defaults: defaults)
        XCTAssertEqual(invalidIDs.activePresetId, .plum)
        XCTAssertNil(invalidIDs.activeCustomThemeId)
        XCTAssertEqual(invalidIDs.activeColors, PresetThemeId.plum.colors)
    }

    func testMissingCustomThemeFallsBackToValidPresetThenPlum() {
        let missingCustomID = UUID()
        defaults.set(missingCustomID.uuidString, forKey: "theme_customThemeId")
        defaults.set(PresetThemeId.lavender.rawValue, forKey: "theme_presetId")

        let validPreset = ThemeManager(defaults: defaults)
        XCTAssertEqual(validPreset.activePresetId, .lavender)
        XCTAssertNil(validPreset.activeCustomThemeId)
        XCTAssertEqual(validPreset.activeColors, PresetThemeId.lavender.colors)

        defaults.removeObject(forKey: "theme_presetId")
        let noValidSelection = ThemeManager(defaults: defaults)
        XCTAssertEqual(noValidSelection.activePresetId, .plum)
        XCTAssertNil(noValidSelection.activeCustomThemeId)
        XCTAssertEqual(noValidSelection.activeColors, PresetThemeId.plum.colors)
    }

    func testUnknownCustomSelectionFallsBackToPlumAndPersistsSafely() {
        let unknownID = UUID()

        do {
            let first = ThemeManager(defaults: defaults)
            first.selectPreset(.ocean)
            first.selectCustomTheme(unknownID)

            XCTAssertNil(first.activeCustomThemeId)
            XCTAssertEqual(first.activePresetId, .plum)
            XCTAssertEqual(first.activeColors, PresetThemeId.plum.colors)
        }

        let second = ThemeManager(defaults: defaults)
        XCTAssertNil(second.activeCustomThemeId)
        XCTAssertEqual(second.activePresetId, .plum)
        XCTAssertEqual(second.activeColors, PresetThemeId.plum.colors)
    }
}
