import XCTest
@testable import GrannyCore

final class TaskParserTests: XCTestCase {
    func testSplitsOnSemicolonCommaNewline() {
        let tasks = TaskParser.parse("Apply 5 jobs; Đọc blog AI\nViết docs, chạy quảng cáo")
        XCTAssertEqual(tasks.count, 4)
        XCTAssertEqual(tasks[0].title, "Apply 5 jobs")
        XCTAssertEqual(tasks[3].title, "chạy quảng cáo")
    }

    func testEmptyInput() {
        XCTAssertTrue(TaskParser.parse("   \n  ;; ").isEmpty)
    }

    func testApplyInfersLinkedInSurfaces() {
        let surfaces = TaskParser.surfaces(for: "Apply 5 jobs")
        XCTAssertTrue(surfaces.contains("linkedin.com/jobs*"))
    }

    func testAdsInfersFacebookAndTikTokSurfaces() {
        let surfaces = TaskParser.surfaces(for: "Chạy quảng cáo Facebook và TikTok")
        XCTAssertTrue(surfaces.contains("facebook.com/adsmanager*"))
        XCTAssertTrue(surfaces.contains("ads.tiktok.com/*"))
    }

    func testStudyInfersReadingSurfaces() {
        let surfaces = TaskParser.surfaces(for: "Học AI bằng việc đọc blog")
        XCTAssertTrue(surfaces.contains("medium.com/*"))
    }

    func testNoKeywordMeansNoSurfaces() {
        XCTAssertTrue(TaskParser.surfaces(for: "Dọn nhà").isEmpty)
    }

    func testParseAssignsSurfacesToTasks() {
        let tasks = TaskParser.parse("Apply 5 jobs")
        XCTAssertEqual(tasks.first?.allowedSurfaces, ["linkedin.com/job*", "linkedin.com/jobs*"])
    }

    func testBulletsAreStripped() {
        let tasks = TaskParser.parse("• Apply 5 jobs\n• Đọc blog AI\n- Viết docs")
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks[0].title, "Apply 5 jobs")
        XCTAssertEqual(tasks[1].title, "Đọc blog AI")
        XCTAssertEqual(tasks[2].title, "Viết docs")
    }

    func testEmptyBulletLinesAreDropped() {
        XCTAssertTrue(TaskParser.parse("• \n• \n").isEmpty)
    }

    func testMovedDomainsAreCanonicalised() {
        XCTAssertEqual(TaskParser.canonicalSurface("threads.net*"), "threads.com*")
        XCTAssertEqual(TaskParser.canonicalSurface("threads.net/feed*"), "threads.com/feed*")
        XCTAssertEqual(TaskParser.canonicalSurface("THREADS.NET"), "threads.com")
        XCTAssertEqual(TaskParser.canonicalSurface("example.com/*"), "example.com/*")
    }

    func testNormalizeSurface() {
        XCTAssertEqual(TaskParser.normalizeSurface(" https://Threads.net/feed "), "threads.com/feed")
        XCTAssertEqual(TaskParser.normalizeSurface("threads.com/"), "threads.com")
        XCTAssertEqual(TaskParser.normalizeSurface("github.com/new*"), "github.com/new*")
        XCTAssertNil(TaskParser.normalizeSurface(""))
        XCTAssertNil(TaskParser.normalizeSurface("dọn nhà"))
    }

    func testRefinedMergeRules() {
        let mine = TaskItem(
            title: "Apply to one job",
            purpose: "Send one tailored application",
            allowedSurfaces: ["linkedin.com/jobs*"])
        let engine = TaskItem(
            title: "Apply to one job",
            purpose: "Job hunting",
            allowedSurfaces: ["linkedin.com/jobs*", "vietnamworks.com/*"])

        // Untouched surfaces: the model refreshes them; a purpose the user
        // wrote survives the model's.
        let refreshed = TaskParser.refined(mine, with: engine, surfacesEdited: false)
        XCTAssertEqual(refreshed.allowedSurfaces, engine.allowedSurfaces)
        XCTAssertEqual(refreshed.purpose, mine.purpose)
        XCTAssertEqual(refreshed.id, mine.id)

        // Hand-edited surfaces: the model's list is ignored.
        let kept = TaskParser.refined(mine, with: engine, surfacesEdited: true)
        XCTAssertEqual(kept.allowedSurfaces, mine.allowedSurfaces)

        // An empty purpose gets filled from the model.
        var blank = mine
        blank.purpose = nil
        XCTAssertEqual(TaskParser.refined(blank, with: engine, surfacesEdited: true).purpose, engine.purpose)
    }
}
