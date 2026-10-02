import XCTest
@testable import GrannyCore

final class EngineAndStateTests: XCTestCase {
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("granny-state-\(UUID().uuidString).json")
    }

    func testFreshStoreHasNoTasks() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StateStore(url: url)
        XCTAssertTrue(store.state.tasks.isEmpty)
        XCTAssertFalse(store.state.dayOff)
    }

    func testRolloverResetsStaleState() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let stale = DayState(
            date: "2000-01-01",
            dayOff: true,
            greeted: true,
            tasks: [TaskItem(title: "old task", done: true)])
        try JSON.encode(stale)!.write(to: url)

        let store = StateStore(url: url)
        XCTAssertNotEqual(store.state.date, "2000-01-01")
        XCTAssertTrue(store.state.tasks.isEmpty)
        XCTAssertFalse(store.state.dayOff)
    }

    func testRolloverCarriesUnfinishedTasks() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let stale = DayState(
            date: "2000-01-01",
            greeted: true,
            tasks: [TaskItem(title: "done", done: true), TaskItem(title: "frog")])
        try JSON.encode(stale)!.write(to: url)

        let store = StateStore(url: url)
        XCTAssertTrue(store.state.tasks.isEmpty)
        XCTAssertEqual(store.state.carried.map(\.title), ["frog"])
        XCTAssertTrue(store.state.carried.allSatisfy(\.carriedOver))
        XCTAssertFalse(store.state.greeted)
    }

    func testLegacyStateWithoutCarryOverFieldsDecodes() throws {
        let json = #"{"date":"2000-01-01","dayOff":false,"greeted":true,"tasks":[{"id":"1","title":"legacy","allowedSurfaces":["github.com/*"],"done":false}]}"#
        let state = try XCTUnwrap(JSON.decode(DayState.self, from: Data(json.utf8)))
        XCTAssertEqual(state.tasks.map(\.title), ["legacy"])
        XCTAssertFalse(state.tasks[0].carriedOver)
        XCTAssertTrue(state.carried.isEmpty)
        XCTAssertEqual(state.streak, 0)
        XCTAssertNil(state.streakDay)
    }

    // MARK: - Streak

    private func day(_ offset: Int, from now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        dayString(calendar.date(byAdding: .day, value: offset, to: now) ?? now, calendar: calendar)
    }

    func testStreakGrowsOnConsecutiveCleanDays() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let calendar = Calendar(identifier: .gregorian)
        let store = StateStore(url: url, calendar: calendar)
        store.update { state in
            state.date = self.day(-1, calendar: calendar)
            state.tasks = [TaskItem(title: "done", done: true)]
            state.streak = 1
            state.streakDay = self.day(-2, calendar: calendar)
        }

        let event = store.rolloverIfNeeded(now: Date())
        XCTAssertEqual(event, .kept(2))
        XCTAssertEqual(store.state.streak, 2)
        XCTAssertEqual(store.state.streakDay, day(-1, calendar: calendar))
    }

    func testFirstCleanDayStaysQuiet() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let calendar = Calendar(identifier: .gregorian)
        let store = StateStore(url: url, calendar: calendar)
        store.update { state in
            state.date = self.day(-1, calendar: calendar)
            state.tasks = [TaskItem(title: "done", done: true)]
        }

        let event = store.rolloverIfNeeded(now: Date())
        XCTAssertNil(event)
        XCTAssertEqual(store.state.streak, 1)
    }

    func testStreakBreaksOnUnfinishedFrogs() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let calendar = Calendar(identifier: .gregorian)
        let store = StateStore(url: url, calendar: calendar)
        store.update { state in
            state.date = self.day(-1, calendar: calendar)
            state.tasks = [TaskItem(title: "frog")]
            state.streak = 3
            state.streakDay = self.day(-2, calendar: calendar)
        }

        let event = store.rolloverIfNeeded(now: Date())
        XCTAssertEqual(event, .lost(3))
        XCTAssertEqual(store.state.streak, 0)
        XCTAssertNil(store.state.streakDay)
        XCTAssertEqual(store.state.carried.map(\.title), ["frog"])
    }

    func testDayOffFreezesTheStreak() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let calendar = Calendar(identifier: .gregorian)
        let store = StateStore(url: url, calendar: calendar)
        store.update { state in
            state.date = self.day(-1, calendar: calendar)
            state.dayOff = true
            state.streak = 4
            state.streakDay = self.day(-2, calendar: calendar)
        }

        let event = store.rolloverIfNeeded(now: Date())
        XCTAssertNil(event)
        XCTAssertEqual(store.state.streak, 4)
        XCTAssertEqual(store.state.streakDay, day(-1, calendar: calendar))
    }

    func testMissedDaysBreakTheStreak() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let calendar = Calendar(identifier: .gregorian)
        let store = StateStore(url: url, calendar: calendar)
        store.update { state in
            state.date = self.day(-3, calendar: calendar)
            state.tasks = [TaskItem(title: "done", done: true)]
            state.streak = 5
            state.streakDay = self.day(-4, calendar: calendar)
        }

        let event = store.rolloverIfNeeded(now: Date())
        XCTAssertEqual(event, .lost(5))
        XCTAssertEqual(store.state.streak, 0)
        XCTAssertNil(store.state.streakDay)
    }

    func testLaunchRolloverBanksTheStreakEvent() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let calendar = Calendar(identifier: .gregorian)
        let seeded = DayState(
            date: day(-1, calendar: calendar),
            tasks: [TaskItem(title: "done", done: true)],
            streak: 1,
            streakDay: day(-2, calendar: calendar))
        try JSON.encode(seeded)!.write(to: url)

        let store = StateStore(url: url, calendar: calendar)
        XCTAssertEqual(store.state.streak, 2)
        XCTAssertEqual(store.drainPendingStreakEvent(), .kept(2))
        XCTAssertNil(store.drainPendingStreakEvent())
    }

    func testDisplayStreakCountsTodayWhenClean() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        var state = DayState(
            date: dayString(now, calendar: calendar),
            tasks: [TaskItem(title: "done", done: true)],
            streak: 1,
            streakDay: day(-1, calendar: calendar))
        XCTAssertEqual(displayStreak(state: state, now: now, calendar: calendar), 2)

        state.tasks = [TaskItem(title: "frog")]
        XCTAssertEqual(displayStreak(state: state, now: now, calendar: calendar), 1)

        state.dayOff = true
        state.tasks = [TaskItem(title: "done", done: true)]
        XCTAssertEqual(displayStreak(state: state, now: now, calendar: calendar), 1)
    }

    func testAllDoneFlag() {
        XCTAssertFalse(DayState(date: "x").allDone)
        XCTAssertFalse(DayState(date: "x", tasks: [TaskItem(title: "a")]).allDone)
        XCTAssertTrue(DayState(date: "x", tasks: [TaskItem(title: "a", done: true), TaskItem(title: "b", done: true)]).allDone)
    }

    func testSurfaceEditPersistsAcrossReload() {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StateStore(url: url)
        let task = TaskItem(title: "Lướt Threads", allowedSurfaces: ["threads.net*"])
        store.update { $0.tasks.append(task) }

        store.update { state in
            if let index = state.tasks.firstIndex(where: { $0.id == task.id }) {
                state.tasks[index].allowedSurfaces = ["threads.com*"]
            }
        }

        let reloaded = StateStore(url: url)
        XCTAssertEqual(reloaded.state.tasks.first?.allowedSurfaces, ["threads.com*"])
    }

    func testEngineRulesTierBlocksWithoutKeys() async {
        let engine = DecisionEngine(config: GrannyConfig())
        let decision = await engine.decide(url: "https://www.facebook.com/", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(decision.action, .block)
        XCTAssertEqual(decision.source, "rules")
    }

    func testEngineUnknownHostGoesThroughClassifier() async {
        let engine = DecisionEngine(config: GrannyConfig())
        // No keys configured: the classifier tiers are skipped and the
        // engine fails open rather than waving the host through in rules.
        let decision = await engine.decide(url: "https://vnexpress.net/", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(decision.action, .allow)
        XCTAssertEqual(decision.source, "failOpen")
    }

    func testEngineAmbiguousWithoutModelsFailsOpen() async {
        let engine = DecisionEngine(config: GrannyConfig())
        let decision = await engine.decide(
            url: "https://www.youtube.com/watch?v=abc", title: "lofi", tasks: [], phase: .working)
        XCTAssertEqual(decision.action, .allow)
        XCTAssertEqual(decision.source, "failOpen")
    }

    func testEngineRewardedPhaseShortCircuits() async {
        let engine = DecisionEngine(config: GrannyConfig())
        let decision = await engine.decide(url: "https://www.tiktok.com/", title: nil, tasks: [], phase: .rewarded)
        XCTAssertEqual(decision.action, .allow)
    }

    func testEngineAsksForContextOnYouTubeWithoutTitle() async {
        let engine = DecisionEngine(config: GrannyConfig())
        let decision = await engine.decide(
            url: "https://www.youtube.com/watch?v=abc", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(decision.action, .needContext)
        XCTAssertEqual(decision.source, "context")
        // need-context is never cached: the retry must reach the model.
        let again = await engine.decide(
            url: "https://www.youtube.com/watch?v=abc", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(again.action, .needContext)
    }

    func testEngineForcedContextSkipsTheWaitAndFailsOpen() async {
        let engine = DecisionEngine(config: GrannyConfig())
        let decision = await engine.decide(
            context: PageContext(url: "https://www.youtube.com/watch?v=abc"),
            tasks: [], phase: .working, force: true)
        XCTAssertEqual(decision.action, .allow)
        XCTAssertEqual(decision.source, "failOpen")
    }

    func testEngineNonContextAmbiguousHostDecidesImmediately() async {
        let engine = DecisionEngine(config: GrannyConfig())
        let decision = await engine.decide(
            url: "https://www.reddit.com/r/swift", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(decision.action, .allow)
        XCTAssertEqual(decision.source, "failOpen")
    }

    func testEngineAllowsNonWebSchemesWithoutJudging() async {
        let engine = DecisionEngine(config: GrannyConfig())
        let decision = await engine.decide(url: "favorites://", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(decision.action, .allow)
        XCTAssertEqual(decision.source, "rules")
        XCTAssertTrue(decision.reason.contains("non-web scheme"))
    }

    func testEngineAmbiguousResultIsCached() async {
        let engine = DecisionEngine(config: GrannyConfig())
        let first = await engine.decide(
            url: "https://www.reddit.com/r/swift", title: nil, tasks: [], phase: .working)
        let second = await engine.decide(
            url: "https://www.reddit.com/r/swift", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(first.action, second.action)
    }

    func testEngineCacheClears() async {
        let engine = DecisionEngine(config: GrannyConfig())
        _ = await engine.decide(url: "https://www.reddit.com/r/swift", title: nil, tasks: [], phase: .working)
        await engine.clearCache()
        let again = await engine.decide(url: "https://www.reddit.com/r/swift", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(again.source, "failOpen")
    }
}
