import XCTest
@testable import GrannyCore

final class PhaseTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)!
    }

    private var config: GrannyConfig { GrannyConfig(wakeHour: 7, bedtimeHour: 23) }

    private func state(tasks: [TaskItem] = [], dayOff: Bool = false, rounds: Int = 0) -> DayState {
        DayState(
            date: dayString(Date(), calendar: calendar),
            dayOff: dayOff,
            tasks: tasks,
            pomodoro: PomodoroRun(finished: rounds))
    }

    func testEmptyTasksDuringDayAwaitsGreeting() {
        let phase = computePhase(now: date(hour: 10), config: config, state: state(), calendar: calendar)
        XCTAssertEqual(phase, .awaitingTasks)
        XCTAssertTrue(phase.blocksActive)
    }

    func testEmptyTasksAtNightIsNight() {
        XCTAssertEqual(computePhase(now: date(hour: 2), config: config, state: state(), calendar: calendar), .night)
        XCTAssertEqual(computePhase(now: date(hour: 23, minute: 30), config: config, state: state(), calendar: calendar), .night)
    }

    func testOpenTasksDuringDayIsWorking() {
        let tasks = [TaskItem(title: "a"), TaskItem(title: "b", done: true)]
        let phase = computePhase(now: date(hour: 10), config: config, state: state(tasks: tasks), calendar: calendar)
        XCTAssertEqual(phase, .working)
        XCTAssertTrue(phase.blocksActive)
    }

    func testAllDoneDuringDayIsRewarded() {
        let tasks = [TaskItem(title: "a", done: true)]
        let phase = computePhase(
            now: date(hour: 10), config: config, state: state(tasks: tasks, rounds: 1),
            calendar: calendar)
        XCTAssertEqual(phase, .rewarded)
        XCTAssertFalse(phase.blocksActive)
    }

    /// The whole rule: ticked boxes buy nothing. A day is paid for with a
    /// finished round, not with three clicks on the list.
    func testTickedBoxesWithoutARoundKeepBlocking() {
        let tasks = [TaskItem(title: "a", done: true), TaskItem(title: "b", done: true)]
        let phase = computePhase(
            now: date(hour: 10), config: config, state: state(tasks: tasks, rounds: 0),
            calendar: calendar)
        XCTAssertEqual(phase, .working)
        XCTAssertTrue(phase.blocksActive)
    }

    func testTodayPaidMeansOneFinishedRound() {
        var today = state(tasks: [TaskItem(title: "a", done: true)])
        XCTAssertFalse(today.paid)
        XCTAssertFalse(today.rewarded)
        today.pomodoro = PomodoroRun(stage: .shortBreak, finished: 1)
        XCTAssertTrue(today.paid)
        XCTAssertTrue(today.rewarded)
        XCTAssertTrue(today.paidThisRound, "the first round is the one that paid")

        today.pomodoro = PomodoroRun(stage: .shortBreak, finished: 2)
        XCTAssertFalse(today.paidThisRound, "later rounds are just more work")
    }

    func testPaidThisRoundNeedsTheReward() {
        var open = state(tasks: [TaskItem(title: "a")], rounds: 1)
        XCTAssertTrue(open.paid)
        XCTAssertFalse(open.paidThisRound)
        open.tasks[0].done = true
        XCTAssertTrue(open.paidThisRound)
    }

    func testUnpaidTicksAreRefused() {
        var unpaid = state(tasks: [TaskItem(title: "a", done: true), TaskItem(title: "b", done: true)])
        XCTAssertTrue(unpaid.refuseUnpaidTicks())
        XCTAssertTrue(unpaid.tasks.allSatisfy { !$0.done }, "a claim with no round comes back off")
        XCTAssertFalse(unpaid.refuseUnpaidTicks(), "an open list has nothing to refuse")

        var paid = state(tasks: [TaskItem(title: "a", done: true)], rounds: 1)
        XCTAssertFalse(paid.refuseUnpaidTicks())
        XCTAssertTrue(paid.tasks[0].done, "a paid day keeps its ticks")
    }

    func testMarkFirstRoundKeepsTheFirst() {
        var today = state()
        today.markFirstRound(now: date(hour: 8, minute: 41), calendar: calendar)
        XCTAssertEqual(today.firstRoundAt, "08:41")
        today.markFirstRound(now: date(hour: 15, minute: 5), calendar: calendar)
        XCTAssertEqual(today.firstRoundAt, "08:41")
    }

    func testAllDoneAfterBedtimeIsNight() {
        let tasks = [TaskItem(title: "a", done: true)]
        XCTAssertEqual(computePhase(now: date(hour: 23, minute: 30), config: config, state: state(tasks: tasks, rounds: 1), calendar: calendar), .night)
    }

    func testDayOffWins() {
        let tasks = [TaskItem(title: "a")]
        let phase = computePhase(now: date(hour: 10), config: config, state: state(tasks: tasks, dayOff: true), calendar: calendar)
        XCTAssertEqual(phase, .dayOff)
        XCTAssertFalse(phase.blocksActive)
    }

    func testWritingATaskCancelsDayOff() {
        var dayOff = state(tasks: [TaskItem(title: "a")], dayOff: true)
        XCTAssertTrue(dayOff.cancelDayOff())
        XCTAssertFalse(dayOff.dayOff)
        XCTAssertFalse(dayOff.cancelDayOff(), "already working: no second flip")
        let phase = computePhase(now: date(hour: 10), config: config, state: dayOff, calendar: calendar)
        XCTAssertEqual(phase, .working)
        XCTAssertTrue(phase.blocksActive)
    }

    func testWakeBoundary() {
        XCTAssertEqual(computePhase(now: date(hour: 6, minute: 59), config: config, state: state(), calendar: calendar), .night)
        XCTAssertEqual(computePhase(now: date(hour: 7, minute: 0), config: config, state: state(), calendar: calendar), .awaitingTasks)
        XCTAssertEqual(computePhase(now: date(hour: 22, minute: 59), config: config, state: state(), calendar: calendar), .awaitingTasks)
    }

    func testBlocksActiveMapping() {
        XCTAssertTrue(Phase.awaitingTasks.blocksActive)
        XCTAssertTrue(Phase.working.blocksActive)
        XCTAssertTrue(Phase.night.blocksActive)
        XCTAssertFalse(Phase.rewarded.blocksActive)
        XCTAssertFalse(Phase.dayOff.blocksActive)
    }
}
