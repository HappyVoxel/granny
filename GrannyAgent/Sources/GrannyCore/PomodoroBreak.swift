import Foundation

/// Whether a pomodoro break lifts the block *right now*: only a running,
/// earned break lifts it, and never in the phase whose block has another
/// purpose.
///
/// `running` is the live in-memory flag, never persisted, so a relaunch
/// mid-break or an expiry while granny was down cannot inherit the holiday:
/// the next launch blocks again, within one tick. `finished > 0` is the
/// "earned" check - a break stage is only reachable by finishing a deep-work
/// round, and there is no control to skip one. Pausing is not running, so
/// pausing blocks again on the next tick.
public func pomodoroBreakLiftsBlock(phase: Phase, run: PomodoroRun, running: Bool) -> Bool {
    // Nothing to lift while the reward is on, and the night block exists to
    // put the user to bed: a tomato must never become a 23:00 unlock.
    guard phase.blocksActive, phase != .night else { return false }
    guard running, run.finished > 0 else { return false }
    return run.stage == .shortBreak || run.stage == .longBreak
}

/// The enforcement truth every consumer receives: the phase, minus a running
/// break. One predicate for the hosts block, `/decide`, the tab janitor and
/// the app killer, so the four ends can never disagree about a lift.
public func blocksEnforced(phase: Phase, run: PomodoroRun, running: Bool) -> Bool {
    phase.blocksActive && !pomodoroBreakLiftsBlock(phase: phase, run: run, running: running)
}
