import Foundation

public struct TaskItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var purpose: String?
    public var allowedSurfaces: [String]
    public var done: Bool
    /// Unfinished yesterday: the notebook marks it with a frog.
    public var carriedOver: Bool

    public init(
        title: String,
        purpose: String? = nil,
        allowedSurfaces: [String] = [],
        done: Bool = false,
        carriedOver: Bool = false
    ) {
        self.id = UUID().uuidString
        self.title = title
        self.purpose = purpose
        self.allowedSurfaces = allowedSurfaces
        self.done = done
        self.carriedOver = carriedOver
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
    /// Unfinished tasks from yesterday, waiting for the morning intake to
    /// merge them into the new notebook.
    public var carried: [TaskItem]
    /// Clean days banked by rollover: a day counts once it ends with tasks
    /// all done; a day off freezes the chain without breaking it.
    public var streak: Int
    /// Last calendar day in the current chain (clean or frozen). Lets the
    /// next rollover tell a continued chain from a fresh start.
    public var streakDay: String?

    public init(
        date: String,
        dayOff: Bool = false,
        greeted: Bool = false,
        tasks: [TaskItem] = [],
        carried: [TaskItem] = [],
        streak: Int = 0,
        streakDay: String? = nil
    ) {
        self.date = date
        self.dayOff = dayOff
        self.greeted = greeted
        self.tasks = tasks
        self.carried = carried
        self.streak = streak
        self.streakDay = streakDay
    }

    public static func fresh(date: String) -> DayState {
        DayState(date: date)
    }

    public var allDone: Bool {
        !tasks.isEmpty && tasks.allSatisfy { $0.done }
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
        streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        streakDay = try c.decodeIfPresent(String.self, forKey: .streakDay)
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
    if !state.dayOff, state.allDone, state.streakDay == yesterday {
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
    private let calendar: Calendar

    public init(url: URL = GrannyPaths.stateURL, calendar: Calendar = .current) {
        self.url = url
        self.calendar = calendar
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

        // Yesterday's carried frogs that the intake never merged must ride
        // along, not be overwritten by the next rollover.
        let unfinished = old.carried + old.tasks.filter { !$0.done }
        state = .fresh(date: today)
        state.carried = unfinished.map { task in
            var carried = task
            carried.carriedOver = true
            return carried
        }

        var event: StreakEvent?
        if old.date != yesterday {
            // A calendar day passed without granny: the chain is dead.
            if old.streak >= 2 { event = .lost(old.streak) }
        } else if old.dayOff {
            // Day off freezes the chain: no day added, none lost.
            state.streak = old.streak
            state.streakDay = old.date
        } else if old.allDone {
            let next = old.streakDay == twoDaysAgo ? old.streak + 1 : 1
            state.streak = next
            state.streakDay = old.date
            if next >= 2 { event = .kept(next) }
        } else if old.streak >= 2 {
            event = .lost(old.streak)
        }
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
