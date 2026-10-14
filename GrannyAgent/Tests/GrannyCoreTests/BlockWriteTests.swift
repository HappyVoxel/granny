import XCTest
@testable import GrannyCore

/// The sandbox seam: only an override pointing somewhere *other* than the real
/// hosts file makes a run sandboxed, and a sandboxed run must not escalate.
final class BlockWriteTests: XCTestCase {
    func testNoOverrideIsNotSandboxed() {
        XCTAssertFalse(isSandboxedHostsRun(override: nil))
    }

    func testEmptyOverrideIsNotSandboxed() {
        XCTAssertFalse(isSandboxedHostsRun(override: ""))
    }

    func testTheRealPathIsNotASandbox() {
        // Pointing the seam at the real file must not buy the sandbox's
        // no-escalation path.
        XCTAssertFalse(isSandboxedHostsRun(override: "/etc/hosts"))
    }

    func testAnotherPathIsSandboxed() {
        XCTAssertTrue(isSandboxedHostsRun(override: "/tmp/granny-sandbox/hosts"))
        XCTAssertTrue(isSandboxedHostsRun(override: "hosts"))
        XCTAssertTrue(isSandboxedHostsRun(override: "/private/etc/hosts"))
    }

    func testRealHostsPathIsConfigurable() {
        XCTAssertFalse(isSandboxedHostsRun(override: "/tmp/hosts", realHostsPath: "/tmp/hosts"))
        XCTAssertTrue(isSandboxedHostsRun(override: "/tmp/hosts", realHostsPath: "/etc/hosts"))
    }
}
