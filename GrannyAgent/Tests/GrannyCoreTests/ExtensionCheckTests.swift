import XCTest
@testable import GrannyCore

final class ExtensionCheckTests: XCTestCase {
    func testSafariDetection() {
        let listing = """
        +    io.github.happyvoxel.granny.safari.Extension(1.0)  UUID  date  /path/appex
        """
        XCTAssertTrue(ExtensionCheck.safari(run: { _, _ in listing }))
        XCTAssertFalse(ExtensionCheck.safari(run: { _, _ in "com.example.other.Extension(1.0)" }))
        XCTAssertFalse(ExtensionCheck.safari(run: { _, _ in nil }), "no output is not an install")
    }

    func testChromiumDetection() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ext-check-\(UUID().uuidString)")
        let profile = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        XCTAssertEqual(ExtensionCheck.chromium(home: home), false,
                       "a browser with an empty profile: not installed")

        let preferences = #"{"extensions":{"settings":{"abc":{"path":"\/Users\/x\/Applications\/granny-extension"}}}}"#
        try preferences.write(
            to: profile.appendingPathComponent("Secure Preferences"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ExtensionCheck.chromium(home: home), true)

        try FileManager.default.removeItem(at: home)
    }

    func testChromiumUnknownWithoutBrowsers() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ext-check-\(UUID().uuidString)")
        XCTAssertNil(ExtensionCheck.chromium(home: home), "no browser: nothing to nag about")
    }
}
