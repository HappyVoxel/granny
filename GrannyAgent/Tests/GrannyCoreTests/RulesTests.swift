import XCTest
@testable import GrannyCore

final class RulesTests: XCTestCase {
    private let engine = RulesEngine(config: GrannyConfig())

    private var adsTask: TaskItem {
        TaskItem(
            title: "Chạy quảng cáo Facebook",
            allowedSurfaces: ["facebook.com/adsmanager*", "business.facebook.com/*", "ads.tiktok.com/*"])
    }

    private var applyTask: TaskItem {
        TaskItem(title: "Apply 5 jobs", allowedSurfaces: ["linkedin.com/jobs*", "linkedin.com/job*"])
    }

    func testBlockedDomainWithoutTask() {
        let decision = engine.evaluate(urlString: "https://www.facebook.com/", tasks: [], phase: .working)
        XCTAssertEqual(decision?.action, .block)
        XCTAssertEqual(decision?.source, "rules")
    }

    func testSubdomainOfBlockedDomainIsBlocked() {
        let decision = engine.evaluate(urlString: "https://m.facebook.com/feed", tasks: [], phase: .working)
        XCTAssertEqual(decision?.action, .block)
    }

    func testPurposefulSurfaceIsAllowed() {
        let decision = engine.evaluate(
            urlString: "https://www.facebook.com/adsmanager/manage/campaigns",
            tasks: [adsTask], phase: .working)
        XCTAssertEqual(decision?.action, .allow)
        XCTAssertNotNil(decision?.message)
    }

    func testWorkHostOutsideSurfaceWarns() {
        let decision = engine.evaluate(urlString: "https://www.facebook.com/", tasks: [adsTask], phase: .working)
        XCTAssertEqual(decision?.action, .warn)
    }

    func testJobSearchAllowedForApplyTask() {
        let decision = engine.evaluate(
            urlString: "https://www.linkedin.com/jobs/search/?keywords=ios",
            tasks: [applyTask], phase: .working)
        XCTAssertEqual(decision?.action, .allow)
    }

    func testLinkedInFeedWarnsWithConnectLine() {
        let decision = engine.evaluate(urlString: "https://www.linkedin.com/feed/", tasks: [applyTask], phase: .working)
        XCTAssertEqual(decision?.action, .warn)
    }

    func testShortsAlwaysBlocked() {
        let decision = engine.evaluate(urlString: "https://www.youtube.com/shorts/abc123", tasks: [adsTask], phase: .working)
        XCTAssertEqual(decision?.action, .block)
        XCTAssertEqual(decision?.reason, "youtube shorts")
    }

    func testYouTubeWatchHasNoRulesVerdict() {
        XCTAssertNil(engine.evaluate(urlString: "https://www.youtube.com/watch?v=abc", tasks: [], phase: .working))
    }

    func testUnknownHostHasNoRulesVerdict() {
        XCTAssertNil(engine.evaluate(urlString: "https://vnexpress.net/tin-tuc", tasks: [], phase: .working))
    }

    func testAdultSitesBlocked() {
        XCTAssertEqual(engine.evaluate(urlString: "https://www.pornhub.com/", tasks: [], phase: .working)?.action, .block)
        XCTAssertEqual(engine.evaluate(urlString: "https://xvideos.com/", tasks: [], phase: .working)?.action, .block)
        XCTAssertEqual(engine.evaluate(urlString: "https://onlyfans.com/user", tasks: [], phase: .working)?.action, .block)
    }

    func testGameSitesBlocked() {
        XCTAssertEqual(engine.evaluate(urlString: "https://gamevui.vn/", tasks: [], phase: .working)?.action, .block)
        XCTAssertEqual(engine.evaluate(urlString: "https://www.y8.com/games/x", tasks: [], phase: .working)?.action, .block)
        XCTAssertEqual(engine.evaluate(urlString: "https://poki.com/vn", tasks: [], phase: .working)?.action, .block)
    }

    func testGamblingSitesBlocked() {
        XCTAssertEqual(engine.evaluate(urlString: "https://188bet.com/", tasks: [], phase: .working)?.action, .block)
        XCTAssertEqual(engine.evaluate(urlString: "https://fun88.com/", tasks: [], phase: .working)?.action, .block)
    }

    func testFocusMusicAlwaysAllowed() {
        let decision = engine.evaluate(urlString: "https://music.youtube.com/watch?v=x", tasks: [], phase: .working)
        XCTAssertEqual(decision?.action, .allow)
    }

    func testResearchAndCommsToolsAlwaysAllowed() {
        for url in [
            "https://www.perplexity.ai/search?q=swift",
            "https://discord.com/channels/123",
            "https://app.slack.com/client/T1/C2",
            "https://us.cloud.langfuse.com/project/x/traces?peek=abc",
        ] {
            XCTAssertEqual(engine.evaluate(urlString: url, tasks: [], phase: .working)?.action, .allow, url)
        }
    }

    func testStreamPatternBlocked() {
        let decision = engine.evaluate(urlString: "https://xoilac123.tv/tran-dau", tasks: [], phase: .working)
        XCTAssertEqual(decision?.action, .block)
        XCTAssertEqual(decision?.reason, "blocked pattern")
    }

    func testDoneTaskDoesNotGrantSurfaces() {
        var task = adsTask
        task.done = true
        let decision = engine.evaluate(
            urlString: "https://www.facebook.com/adsmanager/manage",
            tasks: [task], phase: .working)
        XCTAssertEqual(decision?.action, .block)
    }

    func testRewardedPhaseAllowsEverything() {
        let decision = engine.evaluate(urlString: "https://www.facebook.com/", tasks: [], phase: .rewarded)
        XCTAssertEqual(decision?.action, .allow)
    }

    func testShouldKill() {
        let apps = GrannyConfig.default.entertainmentApps
        XCTAssertTrue(shouldKill(bundleID: apps[0], phase: .working, entertainmentApps: apps))
        XCTAssertFalse(shouldKill(bundleID: apps[0], phase: .rewarded, entertainmentApps: apps))
        XCTAssertFalse(shouldKill(bundleID: "com.apple.Safari", phase: .working, entertainmentApps: apps))
    }

    func testShouldCloseTab() {
        let config = GrannyConfig()
        XCTAssertTrue(shouldCloseTab(urlString: "https://www.facebook.com/", config: config, tasks: [], phase: .working))
        XCTAssertTrue(shouldCloseTab(urlString: "https://www.instagram.com/", config: config, tasks: [], phase: .working))
        XCTAssertTrue(shouldCloseTab(urlString: "https://www.pornhub.com/", config: config, tasks: [], phase: .working))
        XCTAssertTrue(shouldCloseTab(urlString: "https://www.youtube.com/shorts/abc", config: config, tasks: [], phase: .working))
        XCTAssertFalse(shouldCloseTab(urlString: "https://vnexpress.net/", config: config, tasks: [], phase: .working))
        XCTAssertFalse(shouldCloseTab(urlString: "https://www.youtube.com/watch?v=x", config: config, tasks: [], phase: .working))
    }

    func testShouldCloseTabRespectsTaskSurfaces() {
        let config = GrannyConfig()
        let adsTask = TaskItem(title: "Chạy quảng cáo", allowedSurfaces: ["facebook.com/adsmanager*"])
        // The purposeful surface stays open.
        XCTAssertFalse(shouldCloseTab(
            urlString: "https://www.facebook.com/adsmanager/manage", config: config, tasks: [adsTask], phase: .working))
        // The feed with an ads task is warn-level (the extension warns, the
        // janitor does not close); with no task it is block-level.
        XCTAssertFalse(shouldCloseTab(
            urlString: "https://www.facebook.com/feed", config: config, tasks: [adsTask], phase: .working))
        XCTAssertTrue(shouldCloseTab(
            urlString: "https://www.facebook.com/feed", config: config, tasks: [], phase: .working))
    }

    func testJanitorNeverClosesYouTubeExceptShorts() {
        XCTAssertTrue(janitorNeverCloses(urlString: "https://www.youtube.com/watch?v=x"))
        XCTAssertTrue(janitorNeverCloses(urlString: "https://www.youtube.com/"))
        XCTAssertTrue(janitorNeverCloses(urlString: "https://m.youtube.com/watch?v=x"))
        XCTAssertTrue(janitorNeverCloses(urlString: "https://music.youtube.com/watch?v=x"))
        XCTAssertFalse(janitorNeverCloses(urlString: "https://www.youtube.com/shorts/abc"))
        XCTAssertFalse(janitorNeverCloses(urlString: "https://www.facebook.com/"))
    }

    func testShouldCloseTabYouTubeStaysExceptShorts() {
        let config = GrannyConfig()
        XCTAssertFalse(shouldCloseTab(
            urlString: "https://www.youtube.com/watch?v=any-video", config: config, tasks: [], phase: .working))
        XCTAssertFalse(shouldCloseTab(
            urlString: "https://www.youtube.com/", config: config, tasks: [], phase: .working))
        XCTAssertFalse(shouldCloseTab(
            urlString: "https://music.youtube.com/watch?v=x", config: config, tasks: [], phase: .working))
        XCTAssertTrue(shouldCloseTab(
            urlString: "https://www.youtube.com/shorts/abc", config: config, tasks: [], phase: .working))
    }

    func testShouldCloseTabRespectsPhase() {
        let config = GrannyConfig()
        XCTAssertTrue(shouldCloseTab(
            urlString: "https://www.facebook.com/", config: config, tasks: [], phase: .working))
        XCTAssertFalse(shouldCloseTab(
            urlString: "https://www.facebook.com/", config: config, tasks: [], phase: .rewarded))
        XCTAssertFalse(shouldCloseTab(
            urlString: "https://www.facebook.com/", config: config, tasks: [], phase: .dayOff))
    }

    func testSurfaceMatcher() {
        XCTAssertTrue(RulesEngine.matches(surface: "linkedin.com/jobs*", host: "www.linkedin.com", path: "/jobs/search"))
        XCTAssertTrue(RulesEngine.matches(surface: "facebook.com/adsmanager", host: "facebook.com", path: "/adsmanager"))
        XCTAssertTrue(RulesEngine.matches(surface: "facebook.com/adsmanager", host: "facebook.com", path: "/adsmanager/manage"))
        XCTAssertFalse(RulesEngine.matches(surface: "facebook.com/adsmanager", host: "facebook.com", path: "/feed"))
        XCTAssertTrue(RulesEngine.matches(surface: "linkedin.com/*", host: "linkedin.com", path: "/anything"))
    }

    func testHostOnlyWildcardSurfaceMatchesHostAndSubdomains() {
        XCTAssertTrue(RulesEngine.matches(surface: "threads.com*", host: "threads.com", path: "/"))
        XCTAssertTrue(RulesEngine.matches(surface: "threads.com*", host: "www.threads.com", path: "/feed"))
        XCTAssertFalse(RulesEngine.matches(surface: "threads.com*", host: "notthreads.com", path: "/"))
    }
}
