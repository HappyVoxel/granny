import XCTest
@testable import GrannyCore

final class KeyCheckTests: XCTestCase {
    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func response(_ url: URL, status: Int) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.requestCount = 0
    }

    func testOpenRouterKeyValid() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
            return response(request.url!, status: 200)
        }
        let result = await KeyCheck.openRouter(key: "sk-or-test", session: mockSession())
        XCTAssertEqual(result, .valid)
    }

    func testOpenRouterKeyRejected() async {
        MockURLProtocol.handler = { request in self.response(request.url!, status: 401) }
        let result = await KeyCheck.openRouter(key: "bad", session: mockSession())
        XCTAssertEqual(result, .invalid)
    }

    func testOpenRouterTransportErrorIsUnreachable() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let result = await KeyCheck.openRouter(key: "sk-or-test", session: mockSession())
        XCTAssertEqual(result, .unreachable)
    }

    func testEmptyKeyIsInvalidWithoutARequest() async {
        let result = await KeyCheck.openRouter(key: "", session: mockSession())
        XCTAssertEqual(result, .invalid)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testSystemOneKeyValid() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(request.url?.absoluteString, "https://laya.example/v1/systemone")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer laya-test")
            return response(request.url!, status: 200)
        }
        let result = await KeyCheck.systemOne(
            baseURL: "https://laya.example/v1/", key: "laya-test", session: mockSession())
        XCTAssertEqual(result, .valid)
    }

    func testSystemOneKeyRejected() async {
        MockURLProtocol.handler = { request in self.response(request.url!, status: 403) }
        let result = await KeyCheck.systemOne(
            baseURL: "https://laya.example/v1", key: "bad", session: mockSession())
        XCTAssertEqual(result, .invalid)
    }

    /// The console hands out full endpoints; the key check must not double
    /// the `/systemone` suffix.
    func testSystemOneFullEndpointIsUsedAsGiven() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(request.url?.absoluteString, "https://console.opscom.io/v1/systemone")
            return response(request.url!, status: 200)
        }
        let result = await KeyCheck.systemOne(
            baseURL: "https://console.opscom.io/v1/systemone", key: "laya-test", session: mockSession())
        XCTAssertEqual(result, .valid)
    }

    /// Keyless hosts (the free Zaitlabs deployment) validate without a key.
    func testSystemOneKeylessHostValidatesWithoutAKey() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return response(request.url!, status: 200)
        }
        let result = await KeyCheck.systemOne(
            baseURL: "https://laya.inference.zaitlabs.com/v1", key: "", session: mockSession())
        XCTAssertEqual(result, .valid)
    }

    func testSystemOneGarbageURLIsInvalidWithoutARequest() async {
        let result = await KeyCheck.systemOne(
            baseURL: "not a url", key: "k", session: mockSession())
        XCTAssertEqual(result, .invalid)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }
}
