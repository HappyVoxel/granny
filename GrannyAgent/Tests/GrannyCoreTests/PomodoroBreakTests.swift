import XCTest
@testable import GrannyCore

/// The four conditions of "a break lifts the block": only a running, earned
/// break lifts; pausing blocks again; stale state never lifts; the block
/// returns by itself when the stage ends.
final class PomodoroBreakTests: XCTestCase {
    private let work = PomodoroRun(stage: .deepWork, finished: 0)

    // MARK: - Condition 1: only a running, earned break lifts

    func testFreshTomatoNeverLifts() {
        let deepWork = PomodoroRun(stage: .deepWork, finished: 0)
        XCTAssertFalse(
            pomodoroBreakLiftsBlock(phase: .working, run: deepWork, running: true),
            "a running deep-work round keeps the block")
        XCTAssertTrue(blocksEnforced(phase: .working, run: deepWork, running: true))
    }

    func testBreakMustBeEarned() {
        // Hand-made state: a break stage nobody finished a round for. There
        // is no control that reaches this, but the predicate must be total.
        let unearned = PomodoroRun(stage: .shortBreak, finished: 0)
        XCTAssertFalse(pomodoroBreakLiftsBlock(phase: .working, run: unearned, running: true))
        XCTAssertTrue(blocksEnforced(phase: .working, run: unearned, running: true))
    }

    func testRunningShortBreakLifts() {
        let run = PomodoroRun(stage: .shortBreak, finished: 1)
        XCTAssertTrue(pomodoroBreakLiftsBlock(phase: .working, run: run, running: true))
        XCTAssertFalse(blocksEnforced(phase: .working, run: run, running: true))
    }

    func testRunningLongBreakLifts() {
        let run = PomodoroRun(stage: .longBreak, finished: 4)
        XCTAssertTrue(pomodoroBreakLiftsBlock(phase: .working, run: run, running: true))
        XCTAssertFalse(blocksEnforced(phase: .working, run: run, running: true))
    }

    // MARK: - Condition 2: pausing blocks again

    func testPauseBlocksAgain() {
        // The exact state that lifted a moment ago, with the clock stopped.
        for stage in [PomodoroStage.shortBreak, .longBreak] {
            let run = PomodoroRun(stage: stage, finished: 2)
            XCTAssertTrue(pomodoroBreakLiftsBlock(phase: .working, run: run, running: true))
            XCTAssertFalse(
                pomodoroBreakLiftsBlock(phase: .working, run: run, running: false),
                "paused \(stage.rawValue) is not a holiday")
            XCTAssertTrue(blocksEnforced(phase: .working, run: run, running: false))
        }
    }

    // MARK: - Condition 3: stale state never lifts

    func testStaleStateDoesNotLift() {
        // The relaunch shape: the stage is persisted as a break, the live
        // flag is fresh memory and therefore false.
        let persistedBreak = PomodoroRun(stage: .shortBreak, finished: 1)
        XCTAssertFalse(pomodoroBreakLiftsBlock(phase: .working, run: persistedBreak, running: false))
        XCTAssertTrue(blocksEnforced(phase: .working, run: persistedBreak, running: false))

        let persistedLong = PomodoroRun(stage: .longBreak, finished: 8)
        XCTAssertFalse(pomodoroBreakLiftsBlock(phase: .awaitingTasks, run: persistedLong, running: false))
        XCTAssertTrue(blocksEnforced(phase: .awaitingTasks, run: persistedLong, running: false))
    }

    // MARK: - The phase still decides when there is nothing to lift

    func testNightNeverLifts() {
        let run = PomodoroRun(stage: .shortBreak, finished: 3)
        XCTAssertFalse(pomodoroBreakLiftsBlock(phase: .night, run: run, running: true))
        XCTAssertTrue(blocksEnforced(phase: .night, run: run, running: true))
    }

    func testRewardAndDayOffUnchanged() {
        let breakRun = PomodoroRun(stage: .longBreak, finished: 4)
        for phase in [Phase.rewarded, .dayOff] {
            XCTAssertFalse(blocksEnforced(phase: phase, run: work, running: false))
            XCTAssertFalse(
                blocksEnforced(phase: phase, run: breakRun, running: true),
                "\(phase.rawValue) is off with or without a tomato")
        }
    }

    // MARK: - Condition 4: the lift ends with the stage

    func testExpiryStopsTheLift() {
        // The last tick of a break: the stage is still the break and the
        // clock has stopped, so enforcement is back and the hosts re-apply on
        // the next scheduler tick.
        let expired = PomodoroRun(stage: .shortBreak, finished: 1)
        XCTAssertTrue(pomodoroBreakLiftsBlock(phase: .working, run: expired, running: true))
        // Once the runner has moved on, the next round waits for a click -
        // enforced throughout.
        let nextRound = expired.advanced(PomodoroConfig())
        XCTAssertEqual(nextRound, PomodoroRun(stage: .deepWork, finished: 1))
        XCTAssertTrue(blocksEnforced(phase: .working, run: nextRound, running: false))
    }
}
