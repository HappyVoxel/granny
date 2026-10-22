import XCTest
@testable import GrannyCore

final class RhythmTests: XCTestCase {
    private var directory: URL!
    private var log: URL { directory.appendingPathComponent("state.json.log") }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("granny-rhythm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The window is calendar days, so the report tests count back from a
    /// pinned "now" instead of using fixed dates.
    private func day(
        _ offset: Int,
        firstRound: String? = nil,
        rounds: Int = 0,
        from now: Date = Date()
    ) -> RhythmDay {
        let date = calendar.date(byAdding: .day, value: offset, to: now) ?? now
        return RhythmDay(
            date: dayString(date, calendar: calendar),
            firstRound: firstRound,
            rounds: rounds,
            tasksDone: 1)
    }

    private func report(_ days: [RhythmDay], now: Date = Date()) -> RhythmReport? {
        weeklyRhythm(days, now: now, calendar: calendar)
    }

    func testLogRoundTrips() {
        RhythmLog.append(day(-1, firstRound: "08:41", rounds: 4), to: log)
        RhythmLog.append(day(-2, rounds: 0), to: log)

        let days = RhythmLog.read(log)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first?.firstRound, "08:41")
        XCTAssertEqual(days.first?.rounds, 4)
        XCTAssertNil(days.last?.firstRound)
    }

    func testOneLinePerDay() {
        RhythmLog.append(day(-1, rounds: 1), to: log)
        RhythmLog.append(day(-1, rounds: 9), to: log)
        XCTAssertEqual(RhythmLog.read(log), [day(-1, rounds: 1)])
    }

    func testTheLogIsJSONLines() {
        RhythmLog.append(day(-1, firstRound: "08:41", rounds: 2), to: log)
        RhythmLog.append(day(-2, rounds: 3), to: log)
        let text = try? String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(text?.split(separator: "\n").count, 2)
    }

    func testUnreadableLinesAreSkipped() {
        let good = day(-2, rounds: 2)
        let line = String(data: try! JSONEncoder().encode(good), encoding: .utf8)!
        try? "\(line)\n\nnonsense\n".write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(RhythmLog.read(log), [good])
    }

    /// An append-only file must survive its own growth: a line written before
    /// a field existed decodes with that field's default instead of taking the
    /// whole history with it.
    func testOldLinesDecodeWithDefaults() {
        try? "{\"date\":\"2026-03-01\"}\n".write(to: log, atomically: true, encoding: .utf8)
        let days = RhythmLog.read(log)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.rounds, 0)
        XCTAssertEqual(days.first?.tasksDone, 0)
        XCTAssertEqual(days.first?.tasksOpen, 0)
        XCTAssertEqual(days.first?.dayOff, false)
        XCTAssertNil(days.first?.firstRound)
    }

    /// The log is the only cross-day memory: a log it cannot open must lose
    /// the new line, never the history.
    func testAppendKeepsHistoryWhenTheLogCannotBeOpened() {
        RhythmLog.append(day(-2, rounds: 1), to: log)
        let before = try? String(contentsOf: log, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o400], ofItemAtPath: log.path)

        RhythmLog.append(day(-1, rounds: 9), to: log)

        XCTAssertEqual(try? String(contentsOf: log, encoding: .utf8), before)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: log.path)
    }

    func testReadKeepsTheNewest() {
        for index in 1...9 {
            RhythmLog.append(day(-index, rounds: index), to: log)
        }
        XCTAssertEqual(RhythmLog.read(log, limit: 3).map(\.rounds), [7, 8, 9])
        XCTAssertEqual(RhythmLog.read(log).count, 9, "no limit reads the whole log")
    }

    func testNoReportBelowThreeDays() {
        XCTAssertNil(report([]))
        XCTAssertNil(report([day(-1, firstRound: "08:00")]))
        XCTAssertNil(report([day(-1), day(-2)]))
    }

    func testReportCountsStartedDaysAndSpread() {
        let days = [
            day(-1, firstRound: "08:41", rounds: 4),
            day(-2, firstRound: "09:20", rounds: 2),
            day(-3),
            day(-4, firstRound: "11:05", rounds: 3),
        ]
        let report = report(days)
        XCTAssertEqual(report?.days, 4, "four logged days, four days back from yesterday")
        XCTAssertEqual(report?.started, 3)
        // 08:41 .. 11:05 is 2h24.
        XCTAssertEqual(report?.spreadMinutes, 144)
    }

    func testYoungLogDoesNotClaimAWeek() {
        let report = report([day(-1), day(-2, firstRound: "08:00"), day(-3)])
        XCTAssertEqual(report?.days, 3, "a three-day-old log has not seen seven days")
    }

    func testReportWithOneStartHasNoSpread() {
        let report = report([day(-1, firstRound: "08:41"), day(-2), day(-3)])
        XCTAssertEqual(report?.started, 1)
        XCTAssertNil(report?.spreadMinutes)
    }

    func testReportCountsCalendarDaysNotRows() {
        // Old rows fall out of the window instead of stretching it.
        let days = [
            day(-20, firstRound: "21:00"),
            day(-12, firstRound: "21:00"),
            day(-1, firstRound: "08:00"),
            day(-2, firstRound: "08:00"),
            day(-3, firstRound: "08:00"),
        ]
        let report = report(days)
        XCTAssertEqual(report?.days, 7)
        XCTAssertEqual(report?.started, 3)
        XCTAssertEqual(report?.spreadMinutes, 0)
    }

    func testReadingsFollowTheWindow() {
        let now = Date()
        let days = [
            day(-1, firstRound: "08:41"),
            day(-2),
            day(-3, firstRound: "10:00"),
        ]
        let report = report(days, now: now)
        XCTAssertEqual(report?.firstRounds.count, 3)
        XCTAssertEqual(report?.firstRounds.first, 10 * 60, "oldest first")
        XCTAssertNil(report?.firstRounds[1], "a day with no round has no reading")
        XCTAssertEqual(report?.firstRounds.last, 8 * 60 + 41)
    }

    func testFirstRoundMinute() {
        XCTAssertEqual(day(-1, firstRound: "08:41").firstRoundMinute, 521)
        XCTAssertEqual(day(-1, firstRound: "00:00").firstRoundMinute, 0)
        XCTAssertNil(day(-1).firstRoundMinute)
        XCTAssertNil(day(-1, firstRound: "morning").firstRoundMinute)
    }

    func testClockSpreadNeverSaysZeroHours() {
        XCTAssertEqual(clockSpread(0), "0m")
        XCTAssertEqual(clockSpread(45), "45m")
        XCTAssertEqual(clockSpread(60), "1h")
        XCTAssertEqual(clockSpread(144), "2h24")
    }

    func testDayEntryMirrorsTheState() {
        let state = DayState(
            date: "2026-02-10",
            tasks: [TaskItem(title: "a", done: true), TaskItem(title: "b")],
            pomodoro: PomodoroRun(finished: 3),
            firstRoundAt: "09:15")
        let entry = RhythmDay(state)
        XCTAssertEqual(entry.date, "2026-02-10")
        XCTAssertEqual(entry.firstRound, "09:15")
        XCTAssertEqual(entry.rounds, 3)
        XCTAssertEqual(entry.tasksDone, 1)
        XCTAssertEqual(entry.tasksOpen, 1)
        XCTAssertFalse(entry.dayOff)
    }

    func testStoreReportReadsItsOwnLog() {
        // The same calendar the days are written with: the report windows by
        // calendar day, and a store on another zone would see a different one.
        let store = StateStore(
            url: directory.appendingPathComponent("state.json"), calendar: calendar)
        for offset in 1...4 {
            RhythmLog.append(
                day(-offset, firstRound: "0\(offset):00", rounds: 1), to: store.logURL)
        }
        XCTAssertEqual(store.rhythm()?.days, 4)
        XCTAssertEqual(store.rhythm()?.started, 4)
        // 01:00 .. 04:00.
        XCTAssertEqual(store.rhythm()?.spreadMinutes, 180)
    }
}
