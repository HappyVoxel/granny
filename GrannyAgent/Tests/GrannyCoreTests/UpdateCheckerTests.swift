import XCTest
@testable import GrannyCore

final class UpdateCheckerTests: XCTestCase {
    func testParsesRelease() {
        let data = Data(#"""
        {"tag_name":"v0.2.0","html_url":"https://github.com/HappyVoxel/granny/releases/tag/v0.2.0"}
        """#.utf8)
        let release = UpdateChecker.latestRelease(from: data)
        XCTAssertEqual(release?.version, "0.2.0")
        XCTAssertEqual(
            release?.url.absoluteString,
            "https://github.com/HappyVoxel/granny/releases/tag/v0.2.0")
    }

    func testRejectsGarbage() {
        XCTAssertNil(UpdateChecker.latestRelease(from: Data("{}".utf8)))
        XCTAssertNil(UpdateChecker.latestRelease(from: Data("not json".utf8)))
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.1", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.0.1", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
    }
}
