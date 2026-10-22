import Foundation

/// What a slot is for. The kind is what lets granny put a task in the right
/// hour: the user writes "Apply job tại ABB", the slot at 15:00 is an admin
/// slot, and they meet without anyone typing a time twice.
public enum SlotKind: String, Codable, Sendable, CaseIterable {
    case deepWork
    case admin
    case body
    case rest
    case learn
    case personal
    /// Writing that is not work: the journal, notes to self, a page of a
    /// diary. Its own kind because it is neither a task to finish nor rest.
    case journal
}

/// A tag is a colour and a name on a kind of hour. The seven built-ins are
/// just the seed list: a user may recolour them, rename them, or invent one -
/// so the tag lives in the config and its id, not its enum case, is what a
/// slot points at.
public struct SlotTag: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// nil on an untouched built-in: its name comes from `GrannyLines`, in the
    /// user's language. A renamed or custom tag carries its own words.
    public var name: String?
    /// "#RRGGBB", because the config is read by people.
    public var color: String

    public init(id: String, name: String? = nil, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }

    /// The built-in kind this tag stands for, nil for one the user invented.
    /// Only the built-ins can be matched from a task's words.
    public var kind: SlotKind? { SlotKind(rawValue: id) }

    public var displayName: String {
        name ?? kind.map(GrannyLines.slotKindName) ?? id
    }

    /// Red, green and blue in 0...1, nil when the string is not a colour -
    /// a hand-edited tag must fall back to something instead of trapping.
    public var rgb: (red: Double, green: Double, blue: Double)? {
        let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255)
    }

    public static let defaults: [SlotTag] = [
        SlotTag(id: SlotKind.deepWork.rawValue, color: "#D1A85C"),
        SlotTag(id: SlotKind.journal.rawValue, color: "#78B0A8"),
        SlotTag(id: SlotKind.admin.rawValue, color: "#87A3CC"),
        SlotTag(id: SlotKind.learn.rawValue, color: "#AB91C7"),
        SlotTag(id: SlotKind.body.rawValue, color: "#94B57D"),
        SlotTag(id: SlotKind.rest.rawValue, color: "#B59E87"),
        SlotTag(id: SlotKind.personal.rawValue, color: "#C28C8C"),
    ]
}

/// One entry of the personal day: "09:00, làm việc - deep work".
public struct ScheduleSlot: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// "HH:mm" on the user's own clock. Slides, not commitments: the slot is
    /// a name for an hour, not an appointment.
    public var time: String
    public var label: String
    /// The id of a `SlotTag`. A plain `SlotKind` raw value is still valid -
    /// that is what old configs wrote.
    public var tag: String

    public init(id: String = UUID().uuidString, time: String, label: String, tag: String) {
        self.id = id
        self.time = time
        self.label = label
        self.tag = tag
    }

    /// Minutes since midnight, nil when the time is not readable - a
    /// hand-edited config must not trap, it must show as "fix me".
    public var minute: Int? { Schedule.minute(of: time) }

    // `kind` is not a property any more - it is the key configs written
    // before tags were editable carry, and it still has to decode.
    private enum CodingKeys: String, CodingKey {
        case id, time, label, tag, kind
    }

    // Hand-rolled like the rest of the config: one broken slot must not take
    // the whole timetable with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        // `kind` is the old key: a config written before tags were editable
        // still opens, and its hours keep their colour.
        let storedTag: String? = (try? c.decodeIfPresent(String.self, forKey: .tag)) ?? nil
        let legacyKind: String? = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        tag = storedTag ?? legacyKind ?? SlotKind.admin.rawValue
    }

    /// Written without the legacy key: new files carry `tag` only.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(time, forKey: .time)
        try c.encode(label, forKey: .label)
        try c.encode(tag, forKey: .tag)
    }
}

/// The whole personal day, in the order it happens.
public struct Schedule: Codable, Sendable, Equatable {
    public var slots: [ScheduleSlot]

    public init(slots: [ScheduleSlot] = []) {
        self.slots = slots
    }

    public var sorted: [ScheduleSlot] {
        slots.filter { $0.minute != nil }.sorted { ($0.minute ?? 0) < ($1.minute ?? 0) }
    }

    /// The slot the clock is inside: the last one that has started. Nil before
    /// the first slot of the day, which is not "late" - it is "not yet".
    public func current(at now: Date = Date(), calendar: Calendar = .current) -> ScheduleSlot? {
        let minute = Schedule.minute(of: clockString(now, calendar: calendar)) ?? 0
        return sorted.last { ($0.minute ?? 0) <= minute }
    }

    public func slot(id: String?) -> ScheduleSlot? {
        guard let id else { return nil }
        return slots.first { $0.id == id }
    }

    /// "9:5" to "09:05", so the file and the chips read the same way whatever
    /// the user typed.
    public static func normalized(_ time: String) -> String {
        guard let minute = minute(of: time) else { return time }
        return String(format: "%02d:%02d", minute / minutesPerHour, minute % minutesPerHour)
    }

    /// "9:5" reads as 09:05: a text field is not a form, and a typo here is
    /// not worth a scolding. Unreadable input is nil and stays visible as
    /// such.
    public static func minute(of time: String) -> Int? {
        // "6.30" is how the user writes a time in Vietnamese; the dot is not
        // a typo worth refusing.
        let parts = time
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ".", with: ":")
            .split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * minutesPerHour + minute
    }
}

// The words that say which kind of hour a task wants. Both languages: the
// timetable is the user's, the tasks are written in whichever language they
// think in.
private let kindWords: [SlotKind: [String]] = [
    .admin: ["apply", "job", "cv", "resume", "interview", "email", "invoice", "tax",
             "admin", "nộp", "tuyển", "dụng", "phỏng", "vấn", "giấy", "tờ", "hồ", "sơ"],
    .deepWork: ["feature", "code", "build", "fix", "ship", "implement", "design",
                "polish", "write", "deepwork", "deep work", "refactor",
                "tính", "viết", "sửa", "làm", "việc"],
    .learn: ["read", "study", "learn", "course", "book", "language", "license",
             "đọc", "học", "sách", "ngôn", "ngữ", "bằng", "lái"],
    .body: ["gym", "run", "walk", "workout", "swim", "yoga", "tập", "chạy", "bơi"],
    .rest: ["lunch", "dinner", "breakfast", "break", "eat", "ăn", "trưa", "tối", "nghỉ"],
    .personal: ["sleep", "shower", "meditate", "ngủ", "tắm", "vệ", "sinh", "thiền"],
    .journal: ["journal", "diary", "gratitude", "nhật", "ký", "kí", "viết lách"],
]

/// Drops hour ids whose slot is gone, so a rewritten timetable does not leave
/// tasks pinned to an hour that no longer exists: they would show "-", never
/// be nudged, and never be re-proposed.
public func droppingUnknownSlots(_ tasks: [TaskItem], in schedule: Schedule) -> [TaskItem] {
    let known = Set(schedule.slots.map(\.id))
    return tasks.map { task in
        guard let slotID = task.slotID, !known.contains(slotID) else { return task }
        var copy = task
        copy.slotID = nil
        return copy
    }
}

/// Assigns today's tasks to today's slots, in list order: same kind first, a
/// slot only used once, and the earliest slot of the kind preferred. It is a
/// proposal - the notebook shows it as a chip the user can move - because a
/// guess that is wrong and silent is worse than no guess at all.
public func proposeSlots(for tasks: [TaskItem], in schedule: Schedule) -> [String: String] {
    var used: Set<String> = []
    var result: [String: String] = [:]
    for task in tasks {
        let kind = kindOf(task)
        let candidates = schedule.sorted.filter { $0.tag == kind.rawValue }
        guard let slot = candidates.first(where: { !used.contains($0.id) }) ?? candidates.first else {
            continue
        }
        used.insert(slot.id)
        result[task.id] = slot.id
    }
    return result
}

/// The kinds in the order ties are broken: the desk first, because being
/// parked at work is the safer mistake.
private let kindOrder: [SlotKind] = [
    .deepWork, .journal, .admin, .learn, .body, .rest, .personal,
]

/// The kind whose words the task's title mentions most. A task with no
/// recognisable word is deep work: the timetable's default hour is the work
/// one, and being put at the desk is the safer guess.
///
/// Whole words, not substrings: "kỹ năng" contains the letters of "ăn" (eat),
/// and a substring match would file a study task under lunch. A phrase
/// ("viết lách", "deep work") is matched against the raw title and counts
/// double: two words that belong together say more than one verb does.
public func kindOf(_ task: TaskItem) -> SlotKind {
    let text = task.title.lowercased()
    let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    var best: (kind: SlotKind, score: Int) = (.deepWork, 0)
    for kind in kindOrder {
        let vocabulary = kindWords[kind] ?? []
        let score = vocabulary.reduce(0) { total, entry in
            entry.contains(" ")
                ? total + (text.contains(entry) ? 2 : 0)
                : total + (words.contains(entry) ? 1 : 0)
        }
        if score > best.score { best = (kind, score) }
    }
    return best.kind
}
