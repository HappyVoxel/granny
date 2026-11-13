import Foundation
import XCTest
@testable import GrannyCore

/// Portability fixture corpus (`tests/portability/*.json`), generated from the
/// Swift rules and re-verified on every `swift test` run so any rule drift
/// fails CI and any port (Kotlin, Rust, Dart, mobile) can prove equivalence.
///
/// Regenerate after an intentional rule change:
///   GRANNY_WRITE_PORTABILITY=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PortabilityCorpusTests
final class PortabilityCorpusTests: XCTestCase {
    private struct PhaseCase: Codable, Equatable {
        struct Input: Codable, Equatable {
            var now: String
            var wakeHour: Int
            var bedtimeHour: Int
            var dayOff: Bool
            var tasks: [TaskInput]
            var pomodoroStage: String
            var pomodoroFinished: Int
            var pomodoroRunning: Bool
        }
        struct TaskInput: Codable, Equatable {
            var title: String
            var done: Bool
        }
        struct Expected: Codable, Equatable {
            var phase: String
            var blocksEnforced: Bool
        }
        var id: String
        var input: Input
        var expected: Expected
    }

    private struct RuleCase: Codable, Equatable {
        struct Input: Codable, Equatable {
            var phase: String
            var url: String
            var blockedDomains: [String]
            var alwaysAllowedURLPrefixes: [String]
            var taskSurfaces: [String]
            var taskDone: Bool
        }
        struct Verdict: Codable, Equatable {
            var action: String
            var reason: String
            var source: String
        }
        struct Expected: Codable, Equatable {
            var verdict: Verdict?
        }
        var id: String
        var input: Input
        var expected: Expected
    }

    private struct KernelCase: Codable {
        struct ConfigInput: Codable {
            var wakeHour: Int
            var bedtimeHour: Int
            var quietStart: Int?
            var quietEnd: Int?
            var nudgesPerDayMax: Int
            var slots: [ScheduleSlot]
        }
        struct Input: Codable {
            var now: String
            var config: ConfigInput
            var state: DayState
            var blocksEnforced: Bool
            var pomodoroRunning: Bool
            var request: EngineEnvelope
        }
        struct Expected: Codable {
            var reply: EngineEnvelope
            var mutated: Bool
            var startedRound: Bool
            var spoken: Bool
            var state: DayState
        }
        var id: String
        var input: Input
        var expected: Expected
    }

    private struct CorpusFile<Case: Codable>: Codable {
        var version: Int
        var cases: [Case]
    }

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GrannyCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // GrannyAgent
        .deletingLastPathComponent()  // repo root

    private static var portabilityDir: URL {
        repoRoot.appendingPathComponent("tests/portability", isDirectory: true)
    }

    private static func parseUTC(_ iso: String) -> Date {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: iso)!
    }

    override func setUp() {
        super.setUp()
        GrannyLines.configure(language: "en")
    }

    // MARK: - Verification (runs in CI)

    func testPortabilityCorpusMatchesSwiftRules() throws {
        if ProcessInfo.processInfo.environment["GRANNY_WRITE_PORTABILITY"] == "1" {
            try writeAllCorpora()
        }

        let phases: CorpusFile<PhaseCase> = try loadCorpus("phases.json")
        XCTAssertGreaterThanOrEqual(phases.cases.count, 8)
        for c in phases.cases {
            XCTAssertEqual(evalPhase(c.input), c.expected, "phase case \(c.id)")
        }

        let rules: CorpusFile<RuleCase> = try loadCorpus("rules.json")
        XCTAssertGreaterThanOrEqual(rules.cases.count, 10)
        for c in rules.cases {
            XCTAssertEqual(evalRule(c.input), c.expected, "rule case \(c.id)")
        }

        let kernel: CorpusFile<KernelCase> = try loadCorpus("kernel.json")
        XCTAssertGreaterThanOrEqual(kernel.cases.count, 10)
        for c in kernel.cases {
            let actual = evalKernel(c.input)
            XCTAssertEqual(try EngineJSON.encoded(actual), try EngineJSON.encoded(c.expected), "kernel case \(c.id)")
        }
    }

    // MARK: - Evaluators

    private func evalPhase(_ input: PhaseCase.Input) -> PhaseCase.Expected {
        var config = GrannyConfig()
        config.wakeHour = input.wakeHour
        config.bedtimeHour = input.bedtimeHour

        var state = DayState.fresh(date: "2026-11-10")
        state.dayOff = input.dayOff
        state.tasks = input.tasks.enumerated().map { idx, t in
            var item = TaskItem(title: t.title, done: t.done)
            item.id = "t-\(idx + 1)"
            return item
        }
        state.pomodoro = PomodoroRun(
            stage: PomodoroStage(rawValue: input.pomodoroStage) ?? .deepWork,
            finished: input.pomodoroFinished)

        let now = Self.parseUTC(input.now)
        let phase = computePhase(now: now, config: config, state: state, calendar: Self.utcCalendar)
        let enforced = blocksEnforced(phase: phase, run: state.pomodoro, running: input.pomodoroRunning)
        return PhaseCase.Expected(phase: phase.rawValue, blocksEnforced: enforced)
    }

    private func evalRule(_ input: RuleCase.Input) -> RuleCase.Expected {
        var config = GrannyConfig()
        config.blockedDomains = input.blockedDomains
        config.alwaysAllowedURLPrefixes = input.alwaysAllowedURLPrefixes

        var task = TaskItem(
            title: "Task",
            allowedSurfaces: input.taskSurfaces,
            done: input.taskDone)
        task.id = "t-1"
        let tasks = input.taskSurfaces.isEmpty && !input.taskDone ? [] : [task]
        let phase = Phase(rawValue: input.phase) ?? .working
        let decision = RulesEngine(config: config).evaluate(
            urlString: input.url,
            tasks: tasks,
            phase: phase)
        return RuleCase.Expected(
            verdict: decision.map {
                RuleCase.Verdict(action: $0.action.rawValue, reason: $0.reason, source: $0.source)
            })
    }

    private func evalKernel(_ input: KernelCase.Input) -> KernelCase.Expected {
        var config = GrannyConfig()
        config.wakeHour = input.config.wakeHour
        config.bedtimeHour = input.config.bedtimeHour
        config.quietStart = input.config.quietStart
        config.quietEnd = input.config.quietEnd
        config.nudgesPerDayMax = input.config.nudgesPerDayMax
        config.schedule = input.config.slots

        var state = input.state
        let priorTaskIDs = Set(state.tasks.map(\.id))
        let outcome = EngineKernel.handle(
            input.request,
            config: config,
            state: &state,
            blocksEnforced: input.blocksEnforced,
            pomodoroRunning: input.pomodoroRunning,
            now: Self.parseUTC(input.now),
            calendar: Self.utcCalendar)

        // Normalize newly generated random task UUIDs so fixtures stay reproducible across runs.
        var normalizedReply = outcome.reply
        var newTaskIndex = 0
        for idx in state.tasks.indices where !priorTaskIDs.contains(state.tasks[idx].id) {
            newTaskIndex += 1
            let generatedID = state.tasks[idx].id
            let placeholder = "generated-\(newTaskIndex)"
            state.tasks[idx].id = placeholder
            if case .object(var fields) = normalizedReply.result,
               case .string(let returnedID) = fields["taskID"],
               returnedID == generatedID
            {
                fields["taskID"] = .string(placeholder)
                normalizedReply.result = .object(fields)
            }
            for kIdx in state.appliedKeys.indices {
                if case .object(var fields) = state.appliedKeys[kIdx].result,
                   case .string(let returnedID) = fields["taskID"],
                   returnedID == generatedID
                {
                    fields["taskID"] = .string(placeholder)
                    state.appliedKeys[kIdx].result = .object(fields)
                }
            }
        }

        return KernelCase.Expected(
            reply: normalizedReply,
            mutated: outcome.mutated,
            startedRound: outcome.startedRound,
            spoken: outcome.spokenText != nil,
            state: state)
    }

    // MARK: - Corpus IO & Seed Cases

    private func loadCorpus<T: Decodable>(_ name: String) throws -> T {
        let url = Self.portabilityDir.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func writeAllCorpora() throws {
        try FileManager.default.createDirectory(
            at: Self.portabilityDir, withIntermediateDirectories: true)

        let phaseInputs: [(String, PhaseCase.Input)] = [
            ("awaiting-tasks-day", .init(now: "2026-11-10T09:00:00Z", wakeHour: 7, bedtimeHour: 23, dayOff: false, tasks: [], pomodoroStage: "deepWork", pomodoroFinished: 0, pomodoroRunning: false)),
            ("before-wake-night", .init(now: "2026-11-10T06:59:00Z", wakeHour: 7, bedtimeHour: 23, dayOff: false, tasks: [], pomodoroStage: "deepWork", pomodoroFinished: 0, pomodoroRunning: false)),
            ("at-bedtime-night", .init(now: "2026-11-10T23:00:00Z", wakeHour: 7, bedtimeHour: 23, dayOff: false, tasks: [.init(title: "Ship PR", done: true)], pomodoroStage: "deepWork", pomodoroFinished: 1, pomodoroRunning: false)),
            ("working-open-tasks", .init(now: "2026-11-10T10:00:00Z", wakeHour: 7, bedtimeHour: 23, dayOff: false, tasks: [.init(title: "Apply", done: false)], pomodoroStage: "deepWork", pomodoroFinished: 0, pomodoroRunning: false)),
            ("unpaid-ticks-still-working", .init(now: "2026-11-10T10:00:00Z", wakeHour: 7, bedtimeHour: 23, dayOff: false, tasks: [.init(title: "Apply", done: true)], pomodoroStage: "deepWork", pomodoroFinished: 0, pomodoroRunning: false)),
            ("paid-all-done-rewarded", .init(now: "2026-11-10T10:00:00Z", wakeHour: 7, bedtimeHour: 23, dayOff: false, tasks: [.init(title: "Apply", done: true)], pomodoroStage: "deepWork", pomodoroFinished: 1, pomodoroRunning: false)),
            ("day-off-beats-night", .init(now: "2026-11-10T23:30:00Z", wakeHour: 7, bedtimeHour: 23, dayOff: true, tasks: [.init(title: "Apply", done: false)], pomodoroStage: "deepWork", pomodoroFinished: 0, pomodoroRunning: false)),
            ("running-short-break-lifts-block", .init(now: "2026-11-10T10:30:00Z", wakeHour: 7, bedtimeHour: 23, dayOff: false, tasks: [.init(title: "Apply", done: false)], pomodoroStage: "shortBreak", pomodoroFinished: 1, pomodoroRunning: true)),
            ("paused-short-break-reblocks", .init(now: "2026-11-10T10:30:00Z", wakeHour: 7, bedtimeHour: 23, dayOff: false, tasks: [.init(title: "Apply", done: false)], pomodoroStage: "shortBreak", pomodoroFinished: 1, pomodoroRunning: false)),
        ]
        try writeCorpus(
            "phases.json",
            CorpusFile(
                version: 1,
                cases: phaseInputs.map { id, input in
                    PhaseCase(id: id, input: input, expected: evalPhase(input))
                }))

        let defaults = GrannyConfig()
        let ruleInputs: [(String, RuleCase.Input)] = [
            ("loopback-allowed", .init(phase: "working", url: "http://127.0.0.1:8080/health", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: [], taskDone: false)),
            ("rewarded-allows-blocked", .init(phase: "rewarded", url: "https://www.reddit.com/r/all", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: [], taskDone: false)),
            ("always-allowed-prefix", .init(phase: "working", url: "https://www.instagram.com/direct/inbox/", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: ["instagram.com/direct"], taskSurfaces: [], taskDone: false)),
            ("task-surface-allows-host", .init(phase: "working", url: "https://www.facebook.com/adsmanager/manage", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: ["facebook.com/adsmanager"], taskDone: false)),
            ("done-task-revokes-surface", .init(phase: "working", url: "https://www.facebook.com/adsmanager/manage", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: ["facebook.com/adsmanager"], taskDone: true)),
            ("blocked-domain-subdomain", .init(phase: "working", url: "https://m.tiktok.com/foryou", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: [], taskDone: false)),
            ("youtube-shorts-blocked", .init(phase: "working", url: "https://www.youtube.com/shorts/abc123", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: [], taskDone: false)),
            ("search-results-allowed", .init(phase: "working", url: "https://www.google.com/search?q=swift+actors", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: [], taskDone: false)),
            ("research-docs-allowed", .init(phase: "working", url: "https://developer.apple.com/documentation/swift", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: [], taskDone: false)),
            ("work-host-outside-surface-warns", .init(phase: "working", url: "https://github.com/trending", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: ["docs.python.org"], taskDone: false)),
            ("linkedin-feed-warns", .init(phase: "working", url: "https://www.linkedin.com/feed/", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: [], taskDone: false)),
            ("unknown-url-returns-nil", .init(phase: "working", url: "https://example.org/article/focus", blockedDomains: defaults.blockedDomains, alwaysAllowedURLPrefixes: [], taskSurfaces: [], taskDone: false)),
        ]
        try writeCorpus(
            "rules.json",
            CorpusFile(
                version: 1,
                cases: ruleInputs.map { id, input in
                    RuleCase(id: id, input: input, expected: evalRule(input))
                }))

        let slot = ScheduleSlot(id: "morning", time: "09:00", label: "Deep work", tag: "deepWork")
        let baseConfig = KernelCase.ConfigInput(
            wakeHour: 7, bedtimeHour: 23, quietStart: 22, quietEnd: 7, nudgesPerDayMax: 2, slots: [slot])

        var openTask = TaskItem(title: "Apply job", slotID: "morning")
        openTask.id = "t-1"
        var doneTask = TaskItem(title: "Write CV", done: true)
        doneTask.id = "t-1"

        var baseState = DayState.fresh(date: "2026-11-10")
        baseState.greeted = true
        baseState.tasks = [openTask]

        var paidState = baseState
        paidState.pomodoro = PomodoroRun(stage: .deepWork, finished: 1)

        var rewardedState = DayState.fresh(date: "2026-11-10")
        rewardedState.greeted = true
        rewardedState.tasks = [doneTask]
        rewardedState.pomodoro = PomodoroRun(stage: .deepWork, finished: 1)

        var dayOffState = DayState.fresh(date: "2026-11-10")
        dayOffState.dayOff = true

        var zeroBudgetState = baseState
        zeroBudgetState.nudgesSent = 2

        var duplicateState = baseState
        duplicateState.appliedKeys = [
            AppliedEngineKey(key: "k-dup", result: .object(["taskID": .string("t-existing")])),
        ]

        let kernelInputs: [(String, KernelCase.Input)] = [
            ("state-read", .init(
                now: "2026-11-10T09:15:00Z", config: baseConfig, state: baseState,
                blocksEnforced: true, pomodoroRunning: false,
                request: .request(id: "k-1", method: "state.read", params: .object([:])))),
            ("task-add-success", .init(
                now: "2026-11-10T09:15:00Z", config: baseConfig, state: baseState,
                blocksEnforced: true, pomodoroRunning: false,
                request: .request(id: "k-2", method: "state.task.add", params: .object([
                    "title": .string("Read paper"),
                    "slotID": .string("morning"),
                ]), key: "add-1"))),
            ("task-add-relocks-rewarded-day", .init(
                now: "2026-11-10T16:00:00Z", config: baseConfig, state: rewardedState,
                blocksEnforced: false, pomodoroRunning: false,
                request: .request(id: "k-3", method: "state.task.add", params: .object([
                    "title": .string("One more email"),
                ]), key: "add-relock"))),
            ("task-add-refuses-day-off", .init(
                now: "2026-11-10T10:00:00Z", config: baseConfig, state: dayOffState,
                blocksEnforced: false, pomodoroRunning: false,
                request: .request(id: "k-4", method: "state.task.add", params: .object([
                    "title": .string("Sneak work"),
                ]), key: "add-off"))),
            ("task-tick-refuses-unpaid-last", .init(
                now: "2026-11-10T09:30:00Z", config: baseConfig, state: baseState,
                blocksEnforced: true, pomodoroRunning: false,
                request: .request(id: "k-5", method: "state.task.tick", params: .object([
                    "taskID": .string("t-1"),
                    "done": .bool(true),
                ]), key: "tick-unpaid"))),
            ("task-tick-paid-rewards-day", .init(
                now: "2026-11-10T10:00:00Z", config: baseConfig, state: paidState,
                blocksEnforced: true, pomodoroRunning: false,
                request: .request(id: "k-6", method: "state.task.tick", params: .object([
                    "taskID": .string("t-1"),
                    "done": .bool(true),
                ]), key: "tick-paid"))),
            ("slot-move-refuses-unknown-slot", .init(
                now: "2026-11-10T10:00:00Z", config: baseConfig, state: baseState,
                blocksEnforced: true, pomodoroRunning: false,
                request: .request(id: "k-7", method: "slot.move", params: .object([
                    "taskID": .string("t-1"),
                    "slotID": .string("nonexistent"),
                ]), key: "slot-bad"))),
            ("round-start-success", .init(
                now: "2026-11-10T09:00:00Z", config: baseConfig, state: baseState,
                blocksEnforced: true, pomodoroRunning: false,
                request: .request(id: "k-8", method: "round.start", params: .object([:]), key: "round-1"))),
            ("notify-speak-refuses-quiet-hours", .init(
                now: "2026-11-10T22:15:00Z", config: baseConfig, state: baseState,
                blocksEnforced: true, pomodoroRunning: false,
                request: .request(id: "k-9", method: "notify.speak", params: .object([
                    "text": .string("Time for work"),
                    "reason": .string("slot"),
                ]), key: "sp-quiet"))),
            ("notify-speak-refuses-over-budget", .init(
                now: "2026-11-10T11:00:00Z", config: baseConfig, state: zeroBudgetState,
                blocksEnforced: true, pomodoroRunning: false,
                request: .request(id: "k-10", method: "notify.speak", params: .object([
                    "text": .string("Third nudge"),
                    "reason": .string("idle"),
                ]), key: "sp-budget"))),
            ("notify-speak-delivers-in-budget", .init(
                now: "2026-11-10T11:00:00Z", config: baseConfig, state: baseState,
                blocksEnforced: true, pomodoroRunning: false,
                request: .request(id: "k-11", method: "notify.speak", params: .object([
                    "text": .string("Start one round"),
                    "reason": .string("idle"),
                ]), key: "sp-ok"))),
            ("duplicate-key-replays-original", .init(
                now: "2026-11-10T11:00:00Z", config: baseConfig, state: duplicateState,
                blocksEnforced: true, pomodoroRunning: false,
                request: .request(id: "k-12", method: "state.task.add", params: .object([
                    "title": .string("Apply job"),
                ]), key: "k-dup"))),
        ]
        try writeCorpus(
            "kernel.json",
            CorpusFile(
                version: 1,
                cases: kernelInputs.map { id, input in
                    KernelCase(id: id, input: input, expected: evalKernel(input))
                }))
    }

    private func writeCorpus<T: Encodable>(_ name: String, _ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try data.write(to: Self.portabilityDir.appendingPathComponent(name), options: .atomic)
    }
}
