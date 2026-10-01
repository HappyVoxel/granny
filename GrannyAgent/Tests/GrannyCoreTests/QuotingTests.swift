import XCTest
@testable import GrannyCore

final class QuotingTests: XCTestCase {
    func testShellQuotingPlain() {
        XCTAssertEqual(Quoting.shell("/tmp/granny domains.json"), "'/tmp/granny domains.json'")
    }

    func testShellQuotingEscapesSingleQuotes() {
        XCTAssertEqual(Quoting.shell("it's"), "'it'\\''s'")
    }

    func testAppleScriptQuotingEscapesBackslashAndQuote() {
        XCTAssertEqual(Quoting.appleScript(#"a "b" \c"#), #""a \"b\" \\c""#)
    }

    func testAppleScriptQuotingEscapesNewlines() {
        XCTAssertEqual(Quoting.appleScript("line1\nline2"), "\"line1\\nline2\"")
        XCTAssertEqual(Quoting.appleScript("line1\r\nline2"), "\"line1\\nline2\"")
    }

    func testAppleScriptQuotingPlainIsSurrounded() {
        XCTAssertEqual(Quoting.appleScript("/usr/bin/say hi"), "\"/usr/bin/say hi\"")
    }
}
