import XCTest
@testable import GrannyCore

final class SupportTests: XCTestCase {
    func testQueryDecodesFormEncoding() {
        let query = parseQuery(
            "/decide?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dx"
                + "&title=Phim+L%E1%BA%BB+Hay%3A+TH%C3%81NH+B%C3%80I&force=1")
        XCTAssertEqual(query["url"], "https://www.youtube.com/watch?v=x")
        XCTAssertEqual(query["title"], "Phim Lẻ Hay: THÁNH BÀI")
        XCTAssertEqual(query["force"], "1")
    }

    func testQueryKeepsLiteralPlus() {
        XCTAssertEqual(parseQuery("/decide?x=a%2Bb")["x"], "a+b")
    }
}
