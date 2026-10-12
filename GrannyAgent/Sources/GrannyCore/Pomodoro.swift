import Foundation

/// The tomato's three stages. Raw values are persisted in the day state.
public enum PomodoroStage: String, Codable, Sendable {
    case deepWork
    case shortBreak
    case longBreak
}

/// The technique's dials, from the config: 25/5/15 with the long break every
/// fourth round - Cirillo's defaults, the ones pomofocus ships.
public struct PomodoroConfig: Codable, Sendable, Equatable {
    public var workMinutes: Int
    public var shortBreakMinutes: Int
    public var longBreakMinutes: Int
    /// A long break lands after every n-th finished round.
    public var longBreakEvery: Int

    public init(
        workMinutes: Int = 25,
        shortBreakMinutes: Int = 5,
        longBreakMinutes: Int = 15,
        longBreakEvery: Int = 4
    ) {
        self.workMinutes = workMinutes
        self.shortBreakMinutes = shortBreakMinutes
        self.longBreakMinutes = longBreakMinutes
        self.longBreakEvery = longBreakEvery
    }

    /// A hand-edited config can hold 0 or a negative: the tomato would then
    /// fire instantly or never. Clamp instead of trusting the file.
    public var resolved: PomodoroConfig {
        func minutes(_ value: Int) -> Int { min(max(value, 1), 24 * 60) }
        return PomodoroConfig(
            workMinutes: minutes(workMinutes),
            shortBreakMinutes: minutes(shortBreakMinutes),
            longBreakMinutes: minutes(longBreakMinutes),
            longBreakEvery: min(max(longBreakEvery, 1), 24))
    }

    // Per-field like the rest of the config, so a hand-edited file that
    // carries only one key keeps the defaults for the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PomodoroConfig()
        workMinutes = (try? c.decodeIfPresent(Int.self, forKey: .workMinutes)) ?? nil ?? d.workMinutes
        shortBreakMinutes = (try? c.decodeIfPresent(Int.self, forKey: .shortBreakMinutes)) ?? nil ?? d.shortBreakMinutes
        longBreakMinutes = (try? c.decodeIfPresent(Int.self, forKey: .longBreakMinutes)) ?? nil ?? d.longBreakMinutes
        longBreakEvery = (try? c.decodeIfPresent(Int.self, forKey: .longBreakEvery)) ?? nil ?? d.longBreakEvery
    }
}

/// The day's tomato. Midnight rolls it back to round one: the number beside
/// the tomato counts instances *today*, so a long break in the morning is
/// "1" again tomorrow.
public struct PomodoroRun: Codable, Sendable, Equatable {
    public var stage: PomodoroStage
    /// Deep-work rounds finished today. Both the number beside the tomato
    /// and the break the round earns derive from it - no second counter to
    /// keep in step.
    public var finished: Int

    public init(stage: PomodoroStage = .deepWork, finished: Int = 0) {
        self.stage = stage
        self.finished = max(0, finished)
    }

    public static let fresh = PomodoroRun()

    /// The number beside the tomato: the round about to run (or running),
    /// and on a break, which break of that kind this is today - "the 3rd
    /// short break", "the 1st long break".
    public func index(longBreakEvery: Int) -> Int {
        let every = min(max(longBreakEvery, 1), 24)
        switch stage {
        case .deepWork: return finished + 1
        case .longBreak: return max(1, finished / every)
        case .shortBreak: return max(1, finished - finished / every)
        }
    }

    /// What the tomato counts down right now.
    public func minutes(_ config: PomodoroConfig) -> Int {
        let config = config.resolved
        switch stage {
        case .deepWork: return config.workMinutes
        case .shortBreak: return config.shortBreakMinutes
        case .longBreak: return config.longBreakMinutes
        }
    }

    /// The stage that follows this one: work earns a break - the long one on
    /// every n-th round - and a break earns the next round.
    public func advanced(_ config: PomodoroConfig) -> PomodoroRun {
        guard stage == .deepWork else {
            return PomodoroRun(stage: .deepWork, finished: finished)
        }
        let finished = self.finished + 1
        let every = config.resolved.longBreakEvery
        return PomodoroRun(
            stage: finished % every == 0 ? .longBreak : .shortBreak,
            finished: finished)
    }
}

/// One mark of the tomato's dial. The dial is the round's clock face: it
/// always has `pomodoroRingPieces` marks, whether the stage is a 5-minute
/// break or a 50-minute round.
public struct PomodoroRingPiece: Equatable, Sendable {
    /// Where the mark sits on the fruit's outline, as a fraction of the whole
    /// path clockwise from the top. A mark the round is inside is cut back to
    /// the second reached, which is what the hand rides.
    public var from: Double
    public var to: Double
    /// False once the round has finished with the mark: the dial keeps its
    /// place, the fruit's colour is gone from it.
    public var lit: Bool
}

/// The tomato's dial, twelve marks to the round - the clock face, not a
/// bar chart.
public let pomodoroRingMarks = 12

/// The marks of the round still holding fruit, plus the empty ones.
///
/// One continuous arc receding smoothly was right and invisible: at 24:39 of a
/// 25-minute round only 1.4% of the ring had gone. Marks make the recession
/// legible - each one drops whole, and the mark the hand is in erodes second
/// by second.
public func pomodoroRingPieces(
    remaining: TimeInterval,
    total: TimeInterval,
    marks: Int = pomodoroRingMarks
) -> [PomodoroRingPiece] {
    guard total > 0, marks > 0 else { return [] }
    let left = min(max(remaining / total, 0), 1)
    let elapsed = 1 - left
    var pieces: [PomodoroRingPiece] = []
    for index in 0..<marks {
        let start = Double(index) / Double(marks)
        let end = Double(index + 1) / Double(marks)
        // A hairline between the marks: a cut you read as a division, not a
        // gap that turns the ring into a ladder.
        let gap = (end - start) * 0.02
        let from = start + gap
        let to = end - gap
        guard to > from else { continue }
        if elapsed >= to {
            pieces.append(PomodoroRingPiece(from: from, to: to, lit: false))
            continue
        }
        // The mark the hand is inside is cut at the hand, and the cut is not
        // inset - it has to sit exactly on the second the round has reached.
        let edge = elapsed > from ? elapsed : from
        pieces.append(PomodoroRingPiece(from: edge, to: to, lit: true))
    }
    return pieces
}
