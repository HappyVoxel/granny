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
