import Foundation

/// A week: long enough to show a pattern, short enough to act on.
public let rhythmWindowDays = 7

/// Below this many logged days there is nothing to say.
public let rhythmMinimumDays = 3

/// A spread needs two starts - one point has none.
private let minimumStartsForSpread = 2

/// One finished day, one line of the day log beside the state file.
///
/// The state file holds only today, so granny forgets everything the moment
/// the date changes - which is why it could never say "you drift". This log is
/// the coach's whole memory: when the first round happened, how many rounds,
/// and what was left open. Append-only, one line per day, written by the
/// rollover that already knows the day is over.
public struct RhythmDay: Codable, Sendable, Equatable {
    public var date: String
    /// Clock time ("HH:mm") the day's first deep-work round finished. Nil on a
    /// day granny never saw a round - the number the whole thing is about.
    public var firstRound: String?
    public var rounds: Int
    public var tasksDone: Int
    public var tasksOpen: Int
    public var dayOff: Bool

    public init(
        date: String,
        firstRound: String? = nil,
        rounds: Int = 0,
        tasksDone: Int = 0,
        tasksOpen: Int = 0,
        dayOff: Bool = false
    ) {
        self.date = date
        self.firstRound = firstRound
        self.rounds = rounds
        self.tasksDone = tasksDone
        self.tasksOpen = tasksOpen
        self.dayOff = dayOff
    }

    public init(_ state: DayState) {
        self.init(
            date: state.date,
            firstRound: state.firstRoundAt,
            rounds: state.pomodoro.finished,
            tasksDone: state.tasks.filter(\.done).count,
            tasksOpen: state.tasks.filter { !$0.done }.count,
            dayOff: state.dayOff)
    }

    /// Minutes since midnight, for the spread. A day whose first round landed
    /// just after midnight reads as late rather than early; that is the
    /// honest reading of a 00:20 round anyway.
    public var firstRoundMinute: Int? {
        let parts = (firstRound ?? "").split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        return hour * minutesPerHour + minute
    }

    // Hand-rolled like `TaskItem`: the log is append-only, so a field added
    // later must decode old lines with its default instead of throwing them
    // away - a synthesized decoder would erase the whole history.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        firstRound = try c.decodeIfPresent(String.self, forKey: .firstRound)
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds) ?? 0
        tasksDone = try c.decodeIfPresent(Int.self, forKey: .tasksDone) ?? 0
        tasksOpen = try c.decodeIfPresent(Int.self, forKey: .tasksOpen) ?? 0
        dayOff = try c.decodeIfPresent(Bool.self, forKey: .dayOff) ?? false
    }
}

/// The day log: JSON lines, written once per rollover.
public enum RhythmLog {
    /// Appends the day unless the log already ends with it. A state file that
    /// rolls over twice (a relaunch mid-rollover, a hand-edited state) must
    /// not count the day twice.
    public static func append(_ day: RhythmDay, to url: URL) {
        if read(url, limit: 1).last?.date == day.date { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(day) else { return }
        data.append(UInt8(ascii: "\n"))
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
        // A log that exists but cannot be opened loses this line, never the
        // history: only the create path writes the file whole.
    }

    /// The newest `limit` days. Unreadable lines are skipped rather than
    /// failing the load - the log is a nicety, never a gate.
    public static func read(_ url: URL, limit: Int = .max) -> [RhythmDay] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let days: [RhythmDay] = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(RhythmDay.self, from: Data(line.utf8))
        }
        return Array(days.suffix(limit))
    }
}

/// What the coach is allowed to say about the last `limit` days.
public struct RhythmReport: Sendable, Equatable {
    public var days: Int
    /// Days that got a first round at all.
    public var started: Int
    /// Latest minus earliest first round, in minutes. Nil below two started
    /// days: a single point has no spread.
    public var spreadMinutes: Int?
    public init(days: Int, started: Int, spreadMinutes: Int? = nil) {
        self.days = days
        self.started = started
        self.spreadMinutes = spreadMinutes
    }
}

/// Nil until `rhythmMinimumDays` are logged: one bad morning is not a pattern,
/// and granny does not diagnose on one data point.
///
/// The window is calendar days, not the last n rows: a day granny never saw
/// left no row, and it is a day with no first round - counting it is the
/// honest reading.
public func weeklyRhythm(
    _ days: [RhythmDay],
    now: Date = Date(),
    calendar: Calendar = .current,
    limit: Int = rhythmWindowDays
) -> RhythmReport? {
    let start = calendar.date(byAdding: .day, value: -limit, to: now) ?? now
    let from = dayString(start, calendar: calendar)
    let until = dayString(now, calendar: calendar)
    let recent = days.filter { $0.date >= from && $0.date < until }
    guard recent.count >= rhythmMinimumDays else { return nil }
    let starts = recent.compactMap(\.firstRoundMinute)
    // At most `limit` days, but the window starts where the log does: a
    // three-day-old install must not read as four skipped days.
    let oldest = days.map(\.date).min()
    let span = oldest.map { oldestDate in
        (1...limit).first { ago in
            let edge = calendar.date(byAdding: .day, value: -ago, to: now) ?? now
            return oldestDate >= dayString(edge, calendar: calendar)
        } ?? limit
    } ?? limit
    return RhythmReport(
        days: span,
        started: starts.count,
        spreadMinutes: starts.count >= minimumStartsForSpread
            ? (starts.max() ?? 0) - (starts.min() ?? 0)
            : nil)
}

/// "2h05", "45m" - a clock distance, not a duration, so it never says "0h".
public func clockSpread(_ minutes: Int) -> String {
    let hours = minutes / minutesPerHour
    let rest = minutes % minutesPerHour
    if hours == 0 { return "\(rest)m" }
    return rest == 0 ? "\(hours)h" : "\(hours)h\(String(format: "%02d", rest))"
}
