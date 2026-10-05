import XCTest
@testable import GrannyCore

final class HostsFileTests: XCTestCase {
    private let clean = """
        ##
        # Host Database
        127.0.0.1 localhost
        255.255.255.255 broadcasthost
        """

    func testRenderInjectsBlockAndPreservesUserLines() {
        let rendered = HostsFile.render(current: clean, domains: ["facebook.com", "tiktok.com"])
        XCTAssertTrue(rendered.contains(HostsFile.markBegin))
        XCTAssertTrue(rendered.contains(HostsFile.markEnd))
        XCTAssertTrue(rendered.contains("127.0.0.1 facebook.com"))
        XCTAssertTrue(rendered.contains("127.0.0.1 tiktok.com"))
        XCTAssertTrue(rendered.contains("127.0.0.1 localhost"))
    }

    func testRenderBlocksIPv6Too() {
        // An IPv4-only block is bypassed over IPv6 by any host with AAAA
        // records; Meta's domains carry them.
        let rendered = HostsFile.render(current: clean, domains: ["facebook.com"])
        XCTAssertTrue(rendered.contains("::1 facebook.com"))
        XCTAssertTrue(rendered.contains("127.0.0.1 facebook.com"))
    }

    func testRenderIsIdempotent() {
        let once = HostsFile.render(current: clean, domains: ["facebook.com"])
        let twice = HostsFile.render(current: once, domains: ["facebook.com"])
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.components(separatedBy: HostsFile.markBegin).count, 2)
    }

    func testRenderReplacesOldBlock() {
        let old = HostsFile.render(current: clean, domains: ["facebook.com"])
        let new = HostsFile.render(current: old, domains: ["tiktok.com"])
        XCTAssertFalse(new.contains("facebook.com"))
        XCTAssertTrue(new.contains("127.0.0.1 tiktok.com"))
        XCTAssertEqual(new.components(separatedBy: HostsFile.markBegin).count, 2)
    }

    func testStripRemovesBlockAndKeepsUserLines() {
        let rendered = HostsFile.render(current: clean, domains: ["facebook.com"])
        let stripped = HostsFile.strip(current: rendered)
        XCTAssertFalse(stripped.contains(HostsFile.markBegin))
        XCTAssertFalse(stripped.contains("facebook.com"))
        XCTAssertTrue(stripped.contains("127.0.0.1 localhost"))
        XCTAssertTrue(stripped.contains("255.255.255.255 broadcasthost"))
    }

    func testStripOnCleanFileIsIdentity() {
        let stripped = HostsFile.strip(current: clean)
        XCTAssertTrue(stripped.contains("127.0.0.1 localhost"))
        XCTAssertFalse(stripped.contains(HostsFile.markBegin))
    }

    func testRoundTripStability() {
        let rendered = HostsFile.render(current: clean, domains: ["a.com", "b.com"])
        XCTAssertEqual(HostsFile.render(current: HostsFile.strip(current: rendered), domains: ["a.com", "b.com"]), rendered)
    }

    func testIsBlockedAndCount() {
        let cleanBlocked = HostsFile.isBlocked(current: clean)
        XCTAssertFalse(cleanBlocked)
        let rendered = HostsFile.render(current: clean, domains: ["a.com", "b.com", "c.com"])
        XCTAssertTrue(HostsFile.isBlocked(current: rendered))
        XCTAssertEqual(HostsFile.blockedDomainCount(current: rendered), 3)
        XCTAssertEqual(HostsFile.blockedDomainCount(current: clean), 0)
    }
}
