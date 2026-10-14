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

    func testCarryOverJoinsWithSemicolonsAndAgreesInNumber() {
        GrannyLines.language = "en"
        let one = GrannyLines.carryOver(tasks: ["Apply 1 job"])
        XCTAssertTrue(one.contains("is still open"))
        XCTAssertTrue(one.contains("that frog"))

        let two = GrannyLines.carryOver(tasks: ["Apply 1 job", "Ship the pipeline"])
        XCTAssertTrue(two.contains("Apply 1 job; Ship the pipeline"))
        XCTAssertTrue(two.contains("are still open"))
        XCTAssertTrue(two.contains("those frogs"))

        GrannyLines.language = "vi"
        let vietnamese = GrannyLines.carryOver(tasks: ["Apply 1 job", "Ship the pipeline"])
        XCTAssertTrue(vietnamese.contains("Apply 1 job; Ship the pipeline"))
        XCTAssertTrue(vietnamese.contains("mấy con ếch"))
    }

    func testUpdateFailureSpeaksTheLanguage() {
        GrannyLines.language = "vi"
        XCTAssertTrue(GrannyLines.updateFailure(UpdateInstaller.UpdateError.checksum).contains("sai checksum"))
        XCTAssertTrue(GrannyLines.updateFailure(UpdateInstaller.UpdateError.download(404)).contains("404"))
        GrannyLines.language = "en"
        XCTAssertTrue(GrannyLines.updateFailure(UpdateInstaller.UpdateError.notWritable).contains("Homebrew"))
        XCTAssertTrue(GrannyLines.updateFailure(UpdateInstaller.UpdateError.brewFailed("boom")).contains("boom"))
    }

    func testUnknownLanguageFallsBackToEnglish() {
        GrannyLines.language = "de"
        XCTAssertEqual(GrannyLines.language, "en")
        XCTAssertEqual(GrannyLines.greeting, EnglishStrings().greeting)
    }
}

extension GrannyLinesTests {
    /// A one-minute stage is reachable from Settings, and granny does not say
    /// "1 minutes" about it.
    func testPomodoroSingularMinute() {
        GrannyLines.language = "en"
        XCTAssertTrue(GrannyLines.pomodoroNext(stage: "deep work", minutes: 1).contains("1 minute of"))
        XCTAssertTrue(GrannyLines.pomodoroNext(stage: "deep work", minutes: 25).contains("25 minutes of"))

        GrannyLines.language = "fi"
        XCTAssertTrue(GrannyLines.pomodoroNext(stage: "työtä", minutes: 1).contains("1 minuutti "))
        XCTAssertTrue(GrannyLines.pomodoroNext(stage: "työtä", minutes: 25).contains("25 minuuttia "))
    }

    /// The tomato says the stage out loud: the colour is the eye's copy.
    func testPomodoroStateReadsTheStageAndTheClock() {
        GrannyLines.language = "en"
        let line = GrannyLines.pomodoroState(stage: GrannyLines.pomodoroStage(.shortBreak), index: 3, clock: "4:12")
        XCTAssertTrue(line.contains("a short break"))
        XCTAssertTrue(line.contains("3"))
        XCTAssertTrue(line.contains("4:12"))

        GrannyLines.language = "vi"
        XCTAssertTrue(GrannyLines.pomodoroStage(.longBreak) == "nghỉ dài")
    }

    /// The break's line has to carry both facts the lift makes necessary:
    /// what to do with the break, and when the blocks come back - in every
    /// language granny speaks.
    func testPomodoroBreakLineNamesTheAdviceAndTheReturn() {
        GrannyLines.language = "en"
        let english = GrannyLines.pomodoroBreakLine(minutes: 5)
        XCTAssertTrue(english.contains("off-screen"))
        XCTAssertTrue(english.contains("stand up"))
        XCTAssertTrue(english.contains("in 5 minutes"))
        XCTAssertTrue(GrannyLines.pomodoroBreakLine(minutes: 1).contains("in 1 minute "))

        GrannyLines.language = "vi"
        let vietnamese = GrannyLines.pomodoroBreakLine(minutes: 5)
        XCTAssertTrue(vietnamese.contains("rời màn hình"))
        XCTAssertTrue(vietnamese.contains("5 phút"))

        GrannyLines.language = "fi"
        let finnish = GrannyLines.pomodoroBreakLine(minutes: 5)
        XCTAssertTrue(finnish.contains("pois näytöltä"))
        XCTAssertTrue(finnish.contains("5 minuutin"))
    }
}
