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

public struct DayState: Codable, Sendable {
    public var date: String
    public var dayOff: Bool
    public var greeted: Bool
    public var tasks: [TaskItem]
    /// Unfinished tasks from yesterday, waiting for the morning intake to
    /// merge them into the new notebook.
    public var carried: [TaskItem]

    public init(
        date: String,
        dayOff: Bool = false,
        greeted: Bool = false,
        tasks: [TaskItem] = [],
        carried: [TaskItem] = []
    ) {
        self.date = date
        self.dayOff = dayOff
        self.greeted = greeted
        self.tasks = tasks
        self.carried = carried
    }

    public static func fresh(date: String) -> DayState {
        DayState(date: date)
    }

    public var allDone: Bool {
        !tasks.isEmpty && tasks.allSatisfy { $0.done }
    }

    // Old state files have no `carried` key; default it instead of resetting.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        dayOff = try c.decodeIfPresent(Bool.self, forKey: .dayOff) ?? false
        greeted = try c.decodeIfPresent(Bool.self, forKey: .greeted) ?? false
        tasks = try c.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        carried = try c.decodeIfPresent([TaskItem].self, forKey: .carried) ?? []
    }
}

public final class StateStore {
    public private(set) var state: DayState
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
        rolloverIfNeeded()
    }

    @discardableResult
    public func rolloverIfNeeded(now: Date = Date()) -> Bool {
        let today = dayString(now, calendar: calendar)
        if state.date != today {
            // Yesterday's carried frogs that the intake never merged must
            // ride along, not be overwritten by the next rollover.
            let unfinished = state.carried + state.tasks.filter { !$0.done }
            state = .fresh(date: today)
            state.carried = unfinished.map { task in
                var carried = task
                carried.carriedOver = true
                return carried
            }
            save()
            return true
        }
        return false
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
