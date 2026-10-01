import XCTest
@testable import GrannyCore

final class GrannyLinesTests: XCTestCase {
    override func tearDown() {
        GrannyLines.language = "en"
        super.tearDown()
    }

    func testVietnameseLines() {
        GrannyLines.language = "vi"
        let line = GrannyLines.killApp(name: "Facebook", task: "Apply 1 job")
        XCTAssertTrue(line.contains("Facebook"))
        XCTAssertTrue(line.contains("Apply 1 job"))
        XCTAssertTrue(line.contains("lướt gì thì lướt"))
        XCTAssertTrue(GrannyLines.closedTab(url: "https://www.facebook.com/groups/1").contains("facebook.com"))
        XCTAssertTrue(GrannyLines.greeting.contains("cháu"))
    }

    func testEnglishLinesKeepTheWarmTone() {
        GrannyLines.language = "en"
        let line = GrannyLines.killApp(name: "Facebook", task: "Apply 1 job")
        XCTAssertTrue(line.contains("Facebook"))
        XCTAssertTrue(line.contains("Apply 1 job"))
        XCTAssertTrue(line.contains("then play"))
        XCTAssertTrue(line.contains("dear"))
        XCTAssertTrue(GrannyLines.greeting.contains("grandchild"))
        XCTAssertTrue(GrannyLines.reward(bedtime: 23).contains("Good grandchild"))
    }

    func testKillAppWithoutTask() {
        GrannyLines.language = "en"
        let english = GrannyLines.killApp(name: "Steam", task: nil)
        XCTAssertTrue(english.contains("Steam"))
        XCTAssertTrue(english.contains("then play"))

        GrannyLines.language = "vi"
        let vietnamese = GrannyLines.killApp(name: "Steam", task: nil)
        XCTAssertTrue(vietnamese.contains("Steam"))
        XCTAssertTrue(vietnamese.contains("lướt gì thì lướt"))
    }

    func testFinnishLines() {
        GrannyLines.language = "fi"
        XCTAssertTrue(GrannyLines.greeting.contains("mummo"))
        XCTAssertTrue(GrannyLines.killApp(name: "Facebook", task: "Raportti").contains("kulta"))
        XCTAssertTrue(GrannyLines.closedTab(url: "https://www.facebook.com/groups/1").contains("facebook.com"))
        XCTAssertTrue(GrannyLines.statusWorking.contains("mummo".capitalized) || GrannyLines.statusWorking.contains("Mummo"))
    }

    func testUnknownLanguageFallsBackToEnglish() {
        GrannyLines.language = "de"
        XCTAssertEqual(GrannyLines.language, "en")
        XCTAssertEqual(GrannyLines.greeting, EnglishStrings().greeting)
    }
}
