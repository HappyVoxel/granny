import Foundation

public struct TaskItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var purpose: String?
    public var allowedSurfaces: [String]
    public var done: Bool
    public var carriedOver: Bool
    /// The user's own notes on the task: the steps, the link, the reason.
    /// Written by hand - the intake never invents it.
    public var detail: String?
    /// The slot of the user's timetable this task belongs to. A proposal
    /// granny makes at intake and the user can move: stored, never recomputed,
    /// so the hour cannot drift under the task.
    public var slotID: String?

    public init(
        title: String,
        purpose: String? = nil,
        allowedSurfaces: [String] = [],
        done: Bool = false,
        carriedOver: Bool = false,
        slotID: String? = nil,
        detail: String? = nil
    ) {
        self.id = UUID().uuidString
        self.title = title
        self.purpose = purpose
        self.allowedSurfaces = allowedSurfaces
        self.done = done
        self.carriedOver = carriedOver
        self.slotID = slotID
        self.detail = detail
    }

    // Hand-rolled so a state file written before `carriedOver` existed still
    // decodes instead of silently resetting the day.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose)
        allowedSurfaces = try c.decodeIfPresent([String].self, forKey: .allowedSurfaces) ?? []
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        carriedOver = try c.decodeIfPresent(Bool.self, forKey: .carriedOver) ?? false
        slotID = try c.decodeIfPresent(String.self, forKey: .slotID)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// What a rollover did to the streak, when it is worth telling the user
/// about (a displayed streak - two days or more - grew or died).
public enum StreakEvent: Equatable, Sendable {
    case kept(Int)
    case lost(Int)
}

public struct DayState: Codable, Sendable {
    public var date: String
    public var dayOff: Bool
    public var greeted: Bool
    public var tasks: [TaskItem]
    public var pomodoro: PomodoroRun
    public var carried: [TaskItem]
    public var streak: Int
    public var streakDay: String?
    public var firstRoundAt: String?
    /// Task ids granny already scolded for finishing off-slot today, so the
    /// line lands once and does not repeat on a re-tick.
    public var nudgedOffSlot: [String]

    public init(
        date: String,
        dayOff: Bool = false,
        greeted: Bool = false,
        tasks: [TaskItem] = [],
        carried: [TaskItem] = [],
        pomodoro: PomodoroRun = .fresh,
        streak: Int = 0,
        streakDay: String? = nil,
        firstRoundAt: String? = nil,
        nudgedOffSlot: [String] = []
    ) {
        self.date = date
        self.dayOff = dayOff
        self.greeted = greeted
        self.tasks = tasks
        self.pomodoro = pomodoro
        self.carried = carried
        self.streak = streak
        self.streakDay = streakDay
        self.firstRoundAt = firstRoundAt
        self.nudgedOffSlot = nudgedOffSlot
    }

    public static func fresh(date: String) -> DayState {
        DayState(date: date)
    }

    public var allDone: Bool {
        !tasks.isEmpty && tasks.allSatisfy { $0.done }
    }

    /// A round was finished today: the day is paid for.
    public var paid: Bool { pomodoro.finished > 0 }

    /// The reward is earned, not ticked: every task done *and* one finished
    /// round. A day of ticked boxes with no round is a day of paperwork, and
    /// it buys nothing - that is the whole rule.
    public var rewarded: Bool { allDone && paid }

    /// The round that paid for the day is the first one; the ones after it are
    /// just more work, and telling the user to go play again would be a lie.
    public var paidThisRound: Bool { rewarded && pomodoro.finished == 1 }

    /// Records the day's first finished round. Later rounds leave it alone:
    /// the log wants when you sat down, not when you stopped.
    public mutating func markFirstRound(now: Date = Date(), calendar: Calendar = .current) {
        guard firstRoundAt == nil else { return }
        firstRoundAt = clockString(now, calendar: calendar)
    }

    /// Yesterday's frogs become today's work without a word typed. Returns
    /// true when there was something to take, so the caller can open the book.
    @discardableResult
    public mutating func takeCarriedFrogs() -> Bool {
        guard !carried.isEmpty else { return false }
        cancelDayOff()
        tasks = carried + tasks
        carried = []
        greeted = true
        return true
    }

    /// "The list is done" with no round behind it is a claim granny refuses -
    /// and she does not keep a tick she refuses to count. Returns true when it
    /// fired, so the caller says why the boxes came back off.
    @discardableResult
    public mutating func refuseUnpaidTicks() -> Bool {
        guard allDone, !paid else { return false }
        for index in tasks.indices { tasks[index].done = false }
        return true
    }

    /// Writing a task cancels the day off: a day off has no tasks by
    /// definition, so new work means the user is back on duty. Returns true
    /// when the flag flipped, so the caller announces it once.
    @discardableResult
    public mutating func cancelDayOff() -> Bool {
        guard dayOff else { return false }
        dayOff = false
        return true
    }

    // Old state files have no `carried` or streak keys; default them instead
    // of resetting.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        dayOff = try c.decodeIfPresent(Bool.self, forKey: .dayOff) ?? false
        greeted = try c.decodeIfPresent(Bool.self, forKey: .greeted) ?? false
        tasks = try c.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        carried = try c.decodeIfPresent([TaskItem].self, forKey: .carried) ?? []
        pomodoro = try c.decodeIfPresent(PomodoroRun.self, forKey: .pomodoro) ?? .fresh
        streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        streakDay = try c.decodeIfPresent(String.self, forKey: .streakDay)
        firstRoundAt = try c.decodeIfPresent(String.self, forKey: .firstRoundAt)
        nudgedOffSlot = try c.decodeIfPresent([String].self, forKey: .nudgedOffSlot) ?? []
    }
}

/// The streak as the UI should show it: days banked by rollover, plus today
/// the moment it is clean. A frozen (day off) day neither adds nor subtracts.
public func displayStreak(
    state: DayState,
    now: Date = Date(),
    calendar: Calendar = .current
) -> Int {
    let yesterday = dayString(
        calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar: calendar)
    if !state.dayOff, state.rewarded, state.streakDay == yesterday {
        return state.streak + 1
    }
    return state.streak
}

public final class StateStore {
    public private(set) var state: DayState
    /// A streak event produced before anyone could listen - the rollover the
    /// initializer runs. The app drains it on its first tick.
    public private(set) var pendingStreakEvent: StreakEvent?
    private let url: URL
    /// The calendar every date in the store is computed with - the rollover's
    /// dates, the log's window and the clock time of a first round alike.
    public let calendar: Calendar
    /// The day log, beside the state file. Its own parameter so a test store
    /// never appends to a path shared with another one.
    public let logURL: URL

    private static let dayLogExtension = "log"

    public init(url: URL = GrannyPaths.stateURL, calendar: Calendar = .current, logURL: URL? = nil) {
        self.url = url
        self.calendar = calendar
        self.logURL = logURL ?? url.appendingPathExtension(StateStore.dayLogExtension)
        GrannyPaths.ensureDirectories()
        if let data = try? Data(contentsOf: url), let saved = JSON.decode(DayState.self, from: data) {
            self.state = saved
        } else {
            self.state = .fresh(date: dayString(Date(), calendar: calendar))
        }
        pendingStreakEvent = rolloverIfNeeded()
    }

    /// Returns and clears the event banked by the initialization rollover; a
    /// launch after midnight must still deliver the notification.
    public func drainPendingStreakEvent() -> StreakEvent? {
        defer { pendingStreakEvent = nil }
        return pendingStreakEvent
    }

    /// The coach's reading of the last `limit` logged days, nil until there
    /// are enough of them to be worth saying.
    public func rhythm(days limit: Int = rhythmWindowDays) -> RhythmReport? {
        weeklyRhythm(RhythmLog.read(logURL, limit: .max), now: Date(), calendar: calendar, limit: limit)
    }

    /// Rolls the day over and banks yesterday's streak. The chain grows on a
    /// day that ended with all tasks done, survives a day off unchanged, and
    /// dies on unfinished tasks or a day granny never saw. Returns an event
    /// only when a displayed streak (two days or more) changed.
    @discardableResult
    public func rolloverIfNeeded(now: Date = Date()) -> StreakEvent? {
        let today = dayString(now, calendar: calendar)
        guard state.date != today else { return nil }
        let old = state
        let yesterday = dayString(
            calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar: calendar)
        let twoDaysAgo = dayString(
            calendar.date(byAdding: .day, value: -2, to: now) ?? now, calendar: calendar)

        let unfinished = old.carried + old.tasks.filter { !$0.done }
        state = .fresh(date: today)
        state.carried = unfinished.map { task in
            var carried = task
            carried.carriedOver = true
            return carried
        }

        var event: StreakEvent?
        if old.date != yesterday {
            if old.streak >= 2 { event = .lost(old.streak) }
        } else if old.dayOff {
            state.streak = old.streak
            state.streakDay = old.date
        } else if old.rewarded {
            let next = old.streakDay == twoDaysAgo ? old.streak + 1 : 1
            state.streak = next
            state.streakDay = old.date
            if next >= 2 { event = .kept(next) }
        } else if old.streak >= 2 {
            event = .lost(old.streak)
        }
        RhythmLog.append(RhythmDay(old), to: logURL)
        save()
        return event
    }

    public func save() {
        guard let data = JSON.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func update(_ mutate: (inout DayState) -> Void) {
        mutate(&state)
        save()
    }
}
