import Foundation

public enum Phase: String, Codable, Sendable {
    /// Work day, tasks not entered yet. Blocks are on.
    case awaitingTasks
    /// Tasks entered, not all done. Blocks are on.
    case working
    /// Work day, tasks all ticked and a round paid. Blocks are off.
    case rewarded
    /// Day off. Blocks are off.
    case dayOff
    /// Outside wake..bedtime hours. Blocks are on, granny also nags about sleep.
    case night

    public var blocksActive: Bool {
        switch self {
        case .awaitingTasks, .working, .night: return true
        case .rewarded, .dayOff: return false
        }
    }
}

public func computePhase(
    now: Date = Date(),
    config: GrannyConfig,
    state: DayState,
    calendar: Calendar = .current
) -> Phase {
    if state.dayOff { return .dayOff }
    let hour = calendar.component(.hour, from: now)
    let awake = hour >= config.wakeHour && hour < config.bedtimeHour

    if state.tasks.isEmpty { return awake ? .awaitingTasks : .night }
    if state.rewarded { return awake ? .rewarded : .night }
    return awake ? .working : .night
}

/// Whether an open notebook counts as an answer to "what are today's tasks?".
/// It does not: the list is empty, so the day is still unasked. A visible
/// draft is the one exception - replacing the notebook would throw away a
/// half-typed task, and granny does not delete work to ask for work.
public enum IntakePrompt {
    public static func shouldAsk(tasksEmpty: Bool, greeted: Bool, hasDraft: Bool) -> Bool {
        tasksEmpty && !greeted && !hasDraft
    }
}
