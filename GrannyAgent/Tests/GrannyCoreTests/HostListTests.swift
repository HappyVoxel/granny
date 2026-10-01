import XCTest
@testable import GrannyCore

final class HostListTests: XCTestCase {
    func testNormalizeStripsSchemePathPortAndWWW() {
        XCTAssertEqual(HostList.normalize(" HTTPS://WWW.Facebook.com/x?y=1 "), "facebook.com")
        XCTAssertEqual(HostList.normalize("threads.net:443"), "threads.net")
        XCTAssertEqual(HostList.normalize("www.perplexity.ai"), "perplexity.ai")
        XCTAssertNil(HostList.normalize("not a host"))
        XCTAssertNil(HostList.normalize("localhost"))
        XCTAssertNil(HostList.normalize(""))
    }

    func testEntriesAddWWWTwin() {
        XCTAssertEqual(HostList.entries(forHost: "threads.net"), ["threads.net", "www.threads.net"])
        XCTAssertEqual(
            HostList.entries(forHost: "threads.net", prefix: "https://"),
            ["https://threads.net", "https://www.threads.net"])
        XCTAssertEqual(HostList.entries(forHost: "www.example.com"), ["www.example.com"])
    }

    func testDisplayCollapsesWWWTwin() {
        let rows = HostList.displayHosts(["facebook.com", "www.facebook.com", "m.facebook.com"])
        XCTAssertEqual(rows, ["facebook.com", "m.facebook.com"])
    }

    func testDisplayKeepsLoneWWW() {
        XCTAssertEqual(HostList.displayHosts(["https://www.example.com"]), ["www.example.com"])
    }

    func testDisplayOnDefaultAllowList() {
        let rows = HostList.displayHosts(GrannyConfig.defaultAlwaysAllowedPrefixes)
        XCTAssertTrue(rows.contains("perplexity.ai"))
        XCTAssertFalse(rows.contains("www.perplexity.ai"))
        XCTAssertTrue(rows.contains("music.youtube.com"))
    }

    func testRemovingHostDropsTwin() {
        let left = HostList.removing(
            host: "facebook.com",
            from: ["facebook.com", "www.facebook.com", "m.facebook.com"])
        XCTAssertEqual(left, ["m.facebook.com"])
    }

    func testDefaultBlockListRoundTripsToEmpty() {
        var entries = GrannyConfig.defaultBlockedDomains
        for row in HostList.displayHosts(entries) {
            entries = HostList.removing(host: row, from: entries)
        }
        XCTAssertTrue(entries.isEmpty, "leftover: \(entries)")
    }
}
