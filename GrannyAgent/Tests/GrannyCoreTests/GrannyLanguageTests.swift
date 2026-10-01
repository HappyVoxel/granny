import XCTest
@testable import GrannyCore

final class GrannyLanguageTests: XCTestCase {
    func testCodeParsing() {
        XCTAssertEqual(GrannyLanguage(code: "en"), .en)
        XCTAssertEqual(GrannyLanguage(code: "VI"), .vi)
        XCTAssertEqual(GrannyLanguage(code: "fi-FI"), .fi)
        XCTAssertNil(GrannyLanguage(code: "fi_FI"))
        XCTAssertNil(GrannyLanguage(code: "de"))
        XCTAssertNil(GrannyLanguage(code: ""))
    }

    func testPreferredPicksFirstSupportedMachineLanguage() {
        XCTAssertEqual(GrannyLanguage.preferred(from: ["vi-VN", "en-US"]), .vi)
        XCTAssertEqual(GrannyLanguage.preferred(from: ["de-DE", "fi-FI"]), .fi)
        XCTAssertEqual(GrannyLanguage.preferred(from: ["de-DE", "fr-FR"]), .en)
        XCTAssertEqual(GrannyLanguage.preferred(from: []), .en)
    }

    func testDisplayNames() {
        XCTAssertEqual(GrannyLanguage.en.displayName, "English")
        XCTAssertEqual(GrannyLanguage.vi.displayName, "Tiếng Việt")
        XCTAssertEqual(GrannyLanguage.fi.displayName, "Suomi")
    }

    func testEachLanguageSpeaksItsOwnTongue() {
        XCTAssertTrue(GrannyLanguage.en.strings.greeting.contains("grandchild"))
        XCTAssertTrue(GrannyLanguage.vi.strings.greeting.contains("cháu"))
        XCTAssertTrue(GrannyLanguage.fi.strings.greeting.contains("mummo"))
    }

    func testSettingsCopyIsTranslated() {
        XCTAssertTrue(GrannyLanguage.fi.strings.settingsAIGroup.contains("Tekoäly"))
        XCTAssertEqual(GrannyLanguage.fi.strings.settingsSave, "Tallenna")
        XCTAssertEqual(GrannyLanguage.vi.strings.settingsSave, "Lưu")
        XCTAssertEqual(GrannyLanguage.en.strings.settingsSave, "Save")
    }
}
