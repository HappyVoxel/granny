import XCTest
@testable import GrannyCore

final class GrannyVoiceTests: XCTestCase {
    private let fixture = """
    Albert              en_US    # Hello! My name is Albert.
    Samantha            en_US    # Hello! My name is Samantha.
    Linh (Vietnamese (Vietnam)) vi_VN    # Xin chào! Tên tôi là Linh.
    Daniel              en_GB    # Hello! My name is Daniel.
    Grandma (Finnish (Finland)) fi_FI    # Hei! Nimeni on Grandma.
    """

    func testParsesBaseNameAndLocale() {
        let voices = GrannyVoice.parse(fixture)
        XCTAssertTrue(voices.contains(GrannyVoice.Voice(name: "Samantha", locale: "en_US")))
        XCTAssertTrue(voices.contains(GrannyVoice.Voice(name: "Linh", locale: "vi_VN")))
        XCTAssertTrue(voices.contains(GrannyVoice.Voice(name: "Daniel", locale: "en_GB")))
        XCTAssertTrue(voices.contains(GrannyVoice.Voice(name: "Grandma", locale: "fi_FI")))
    }

    func testFinnishPrefersItsOwnVoice() {
        let voices = GrannyVoice.parse(fixture)
        XCTAssertEqual(GrannyVoice.resolve(configured: nil, language: "fi", voices: voices), "Grandma")
        XCTAssertEqual(GrannyVoice.resolve(configured: "Linh", language: "fi", voices: voices), "Grandma")
    }

    func testConfiguredVoiceWinsWhenLocaleMatches() {
        let voices = GrannyVoice.parse(fixture)
        XCTAssertEqual(GrannyVoice.resolve(configured: "Linh", language: "vi", voices: voices), "Linh")
        XCTAssertEqual(GrannyVoice.resolve(configured: "Daniel", language: "en", voices: voices), "Daniel")
    }

    func testMismatchedConfiguredVoiceFallsBackToLanguageDefault() {
        let voices = GrannyVoice.parse(fixture)
        XCTAssertEqual(GrannyVoice.resolve(configured: "Linh", language: "en", voices: voices), "Samantha")
    }

    func testNilConfiguredUsesLanguageDefault() {
        let voices = GrannyVoice.parse(fixture)
        XCTAssertEqual(GrannyVoice.resolve(configured: nil, language: "en", voices: voices), "Samantha")
        XCTAssertEqual(GrannyVoice.resolve(configured: nil, language: "vi", voices: voices), "Linh")
    }

    func testUnknownConfiguredFallsBackToAnyVoiceOfTheLanguage() {
        let voices = [GrannyVoice.Voice(name: "Karen", locale: "en_AU")]
        XCTAssertEqual(GrannyVoice.resolve(configured: "Nope", language: "en", voices: voices), "Karen")
    }

    func testNoVoiceOfTheLanguageReturnsNil() {
        let voices = [GrannyVoice.Voice(name: "Linh", locale: "vi_VN")]
        XCTAssertNil(GrannyVoice.resolve(configured: nil, language: "en", voices: voices))
    }
}
