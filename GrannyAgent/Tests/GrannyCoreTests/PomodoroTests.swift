import XCTest
@testable import GrannyCore

final class PomodoroTests: XCTestCase {
    private let technique = PomodoroConfig()

    func testFreshDayStartsAtRoundOne() {
        let run = PomodoroRun.fresh
        XCTAssertEqual(run.stage, .deepWork)
        XCTAssertEqual(run.index(longBreakEvery: 4), 1, "the round about to run")
        XCTAssertEqual(run.minutes(technique), 25)
    }

    /// The break the round earns: short three times, long on the fourth.
    func testCadenceAfterFourRounds() {
        var run = PomodoroRun.fresh
        for _ in 1...3 {
            run = run.advanced(technique)
            XCTAssertEqual(run.stage, .shortBreak)
            run = run.advanced(technique)
            XCTAssertEqual(run.stage, .deepWork)
        }
        run = run.advanced(technique)
        XCTAssertEqual(run.stage, .longBreak, "the 4th finished round earns the long break")
        XCTAssertEqual(run.finished, 4)
        run = run.advanced(technique)
        XCTAssertEqual(run.stage, .deepWork)
        XCTAssertEqual(run.index(longBreakEvery: 4), 5)
    }

    /// The number outside the tomato: which instance of the stage this is
    /// today - "the 3rd short break", "the 1st long break".
    func testIndexCountsInstancesOfTheStage() {
        let thirdShortBreak = PomodoroRun(stage: .shortBreak, finished: 3)
        XCTAssertEqual(thirdShortBreak.index(longBreakEvery: 4), 3)

        let firstLongBreak = PomodoroRun(stage: .longBreak, finished: 4)
        XCTAssertEqual(firstLongBreak.index(longBreakEvery: 4), 1)

        let secondLongBreak = PomodoroRun(stage: .longBreak, finished: 8)
        XCTAssertEqual(secondLongBreak.index(longBreakEvery: 4), 2)

        // After the 5th round: the short breaks are the ones at 1, 2, 3 and 5.
        let fourthShortBreak = PomodoroRun(stage: .shortBreak, finished: 5)
        XCTAssertEqual(fourthShortBreak.index(longBreakEvery: 4), 4)
    }

    func testCadenceFollowsAConfiguredInterval() {
        let thrice = PomodoroConfig(longBreakEvery: 3)
        var run = PomodoroRun.fresh
        run = run.advanced(thrice)
        XCTAssertEqual(run.stage, .shortBreak, "round 1")
        run = run.advanced(thrice).advanced(thrice)
        XCTAssertEqual(run.stage, .shortBreak, "round 2")
        run = run.advanced(thrice).advanced(thrice)
        XCTAssertEqual(run.finished, 3)
        XCTAssertEqual(run.stage, .longBreak, "every 3rd round, not every 4th")
        XCTAssertEqual(run.index(longBreakEvery: 3), 1)
    }

    func testEachStageUsesItsOwnDuration() {
        let config = PomodoroConfig(workMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 30)
        XCTAssertEqual(PomodoroRun(stage: .deepWork).minutes(config), 50)
        XCTAssertEqual(PomodoroRun(stage: .shortBreak).minutes(config), 10)
        XCTAssertEqual(PomodoroRun(stage: .longBreak).minutes(config), 30)
    }

    /// A hand-edited config with a zero would make the tomato fire instantly.
    func testSillyDurationsAreClamped() {
        let silly = PomodoroConfig(workMinutes: 0, shortBreakMinutes: -5, longBreakMinutes: 0, longBreakEvery: 0)
        XCTAssertEqual(silly.resolved.workMinutes, 1)
        XCTAssertEqual(silly.resolved.shortBreakMinutes, 1)
        XCTAssertEqual(silly.resolved.longBreakMinutes, 1)
        XCTAssertEqual(silly.resolved.longBreakEvery, 1)
        XCTAssertEqual(PomodoroRun(stage: .deepWork).index(longBreakEvery: 0), 1)
    }

    func testConfigKeepsDefaultsForMissingKeys() throws {
        let partial = try XCTUnwrap(JSON.decode(
            PomodoroConfig.self,
            from: Data(#"{"workMinutes": 40}"#.utf8)))
        XCTAssertEqual(partial.workMinutes, 40)
        XCTAssertEqual(partial.shortBreakMinutes, 5)
        XCTAssertEqual(partial.longBreakMinutes, 15)
        XCTAssertEqual(partial.longBreakEvery, 4)
    }

    func testConfigDefaultsOnAConfigWithoutTheKey() throws {
        let config = try XCTUnwrap(JSON.decode(GrannyConfig.self, from: Data(#"{"wakeHour": 6}"#.utf8)))
        XCTAssertEqual(config.wakeHour, 6)
        XCTAssertEqual(config.pomodoro, PomodoroConfig())
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(JSON.encode(config)), as: UTF8.self).contains("pomodoro"),
            true)
    }

    /// The counters are per day: a state file from a day that ended tells
    /// nothing about today, and an older file has no tomato at all.
    func testStateCarriesTheRunAndDefaultsWithoutIt() throws {        let saved = DayState(date: "2026-10-12", pomodoro: PomodoroRun(stage: .shortBreak, finished: 3))
        let roundTripped = try XCTUnwrap(JSON.decode(DayState.self, from: try XCTUnwrap(JSON.encode(saved))))
        XCTAssertEqual(roundTripped.pomodoro, saved.pomodoro)

        let older = try XCTUnwrap(JSON.decode(DayState.self, from: Data(#"{"date": "2026-10-01"}"#.utf8)))
        XCTAssertEqual(older.pomodoro, .fresh)
        XCTAssertEqual(DayState.fresh(date: "2026-10-13").pomodoro, .fresh, "rollover starts the tomato over")
    }

    /// The dial drops one whole mark at a time, so the recession is visible;
    /// a smooth arc had gone 1.4% in 21 seconds and read as untouched.
    func testDialHasTwelveMarksAndDropsThemWhole() {
        let full = pomodoroRingPieces(remaining: 25 * 60, total: 25 * 60)
        XCTAssertEqual(full.count, 12, "a clock face, whatever the stage is")
        XCTAssertTrue(full.allSatisfy(\.lit))
        XCTAssertGreaterThan(full[0].from, 0, "the marks are cut apart")
        XCTAssertLessThan(full[0].from, 0.01, "by a hairline, not a gap")
        XCTAssertEqual(full.last?.to ?? 0, 1 - full[0].from, accuracy: 0.0001)

        // 24:39 - 21 seconds in: the first mark is cut at the hand, the other
        // eleven are whole.
        let early = pomodoroRingPieces(remaining: 24 * 60 + 39, total: 25 * 60)
        XCTAssertEqual(early.count, 12)
        XCTAssertEqual(early[0].from, 21.0 / 1500, accuracy: 0.0005, "the cut sits on the second")
        XCTAssertTrue(early[0].lit, "a partly eaten mark is still fruit")
        XCTAssertTrue(early.dropFirst().allSatisfy(\.lit))

        // A twelfth in: one whole mark is empty now, and it stays on the dial.
        let twoMinutes = pomodoroRingPieces(remaining: 25 * 60 - 125, total: 25 * 60)
        XCTAssertEqual(twoMinutes.count, 12)
        XCTAssertFalse(twoMinutes[0].lit, "finished with it")
        XCTAssertEqual(twoMinutes[0].from, full[0].from, accuracy: 0.0001, "an empty mark keeps its place")
        XCTAssertTrue(twoMinutes[1].lit)

        // Zero: the face is there, the fruit is not.
        let done = pomodoroRingPieces(remaining: 0, total: 25 * 60)
        XCTAssertEqual(done.count, 12)
        XCTAssertTrue(done.allSatisfy { !$0.lit })

        XCTAssertTrue(pomodoroRingPieces(remaining: 60, total: 0).isEmpty, "no length, no dial")
    }

    func testAShortStageGetsTheSameDial() {
        let five = pomodoroRingPieces(remaining: 5 * 60, total: 5 * 60)
        XCTAssertEqual(five.count, 12, "a 5-minute break is a dial too, dropping every 25 seconds")
        // A fifth gone: two marks emptied, and the third cut at the hand.
        let fifth = pomodoroRingPieces(remaining: 4 * 60, total: 5 * 60)
        XCTAssertEqual(fifth.filter(\.lit).count, 10)
        XCTAssertEqual(fifth.filter { !$0.lit }.count, 2)
        XCTAssertEqual(fifth[2].from, 0.2, accuracy: 0.0005)
    }

    /// The day's tomato belongs to the day, so the rollover must clear the
    /// whole run - not just its counters. A break left mid-stage at midnight
    /// is what the live clock used to keep counting.
    func testRolloverStartsTheTomatoOver() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("granny-pomodoro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let dayBefore = calendar.date(byAdding: .day, value: -2, to: now)!

        var saved = DayState(
            date: dayString(yesterday, calendar: calendar),
            greeted: true,
            tasks: [TaskItem(title: "a", done: true)],
            pomodoro: PomodoroRun(stage: .longBreak, finished: 4))
        saved.streak = 3
        // A chain that reached yesterday: `streakDay` is the day before it.
        saved.streakDay = dayString(dayBefore, calendar: calendar)
        try XCTUnwrap(JSON.encode(saved)).write(to: url)

        let store = StateStore(url: url, calendar: calendar)
        XCTAssertEqual(store.state.date, dayString(now, calendar: calendar))
        XCTAssertEqual(store.state.pomodoro, .fresh, "yesterday's break is not today's")
        XCTAssertEqual(store.state.streak, 4, "and the streak still banked")
    }
}
