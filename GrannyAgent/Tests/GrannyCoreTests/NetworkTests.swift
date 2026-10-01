import XCTest
@testable import GrannyCore

/// URLProtocol stub so the model tiers can be tested without a network.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.requestCount += 1
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class NetworkTests: XCTestCase {
    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func response(_ url: URL, status: Int, json: [String: Any]) -> (HTTPURLResponse, Data) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
    }

    private func openRouterOK(_ content: String) -> [String: Any] {
        ["choices": [["message": ["role": "assistant", "content": content]]]]
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.requestCount = 0
    }

    // MARK: - OpenRouter over the wire

    func testOpenRouterDecideSuccess() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertTrue(request.url?.absoluteString.contains("openrouter.ai") ?? false)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            return response(request.url!, status: 200, json: openRouterOK(
                #"{"action":"block","message":"Ngoại cấm nhé.","reason":"feed"}"#))
        }
        let client = OpenRouterClient(
            settings: .init(apiKey: "test-key", model: "deepseek/deepseek-v4.1-flash"),
            session: mockSession())
        let decision = await client.decide(url: "https://x.com/feed", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(decision?.action, .block)
        XCTAssertEqual(decision?.source, "model")
    }

    func testOpenRouterDecideHandlesHTTPError() async {
        MockURLProtocol.handler = { request in
            self.response(request.url!, status: 500, json: ["error": "boom"])
        }
        let client = OpenRouterClient(
            settings: .init(apiKey: "k", model: "m"), session: mockSession())
        let decision = await client.decide(url: "https://x.com/", title: nil, tasks: [], phase: .working)
        XCTAssertNil(decision)
    }

    func testOpenRouterDecideHandlesTransportError() async {
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        let client = OpenRouterClient(
            settings: .init(apiKey: "k", model: "m"), session: mockSession())
        let decision = await client.decide(url: "https://x.com/", title: nil, tasks: [], phase: .working)
        XCTAssertNil(decision)
    }

    func testOpenRouterIntakeOverWire() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: openRouterOK(
                #"{"tasks":[{"title":"Học AI","purpose":"","surfaces":["medium.com/*"]}],"question":"cụ thể là gì?"}"#))
        }
        let client = OpenRouterClient(settings: .init(apiKey: "k", model: "m"), session: mockSession())
        let intake = await client.parseIntake(text: "học AI")
        XCTAssertEqual(intake?.tasks.first?.title, "Học AI")
        XCTAssertEqual(intake?.question, "cụ thể là gì?")
    }

    // MARK: - Laya over the wire

    func testLayaDecideSuccess() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer laya-key")
            return response(request.url!, status: 200, json: [
                "answers": ["action": ["type": "choice", "choice": "warn", "answer_confidence": 0.9]],
            ])
        }
        let client = LayaClient(baseURL: "https://laya.example/v1", apiKey: "laya-key", session: mockSession())
        let decision = await client.decide(url: "https://linkedin.com/feed", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(decision?.action, .warn)
        XCTAssertEqual(decision?.source, "laya")
    }

    func testLayaLowConfidenceReturnsNil() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: [
                "answers": ["action": ["type": "choice", "choice": "block", "answer_confidence": 0.2]],
            ])
        }
        let client = LayaClient(baseURL: "https://laya.example/v1", apiKey: "k", session: mockSession())
        let decision = await client.decide(url: "https://linkedin.com/feed", title: nil, tasks: [], phase: .working)
        XCTAssertNil(decision)
    }

    // MARK: - Trace over the wire

    func testTracePostsOTLPWithBasicAuth() async {
        let expectation = expectation(description: "otlp posted")
        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.hasSuffix("/api/public/otel/v1/traces") ?? false)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-langfuse-ingestion-version"), "4")
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            XCTAssertTrue(auth.hasPrefix("Basic "))
            let decoded = Data(base64Encoded: String(auth.dropFirst("Basic ".count)))
            XCTAssertEqual(decoded.map { String(decoding: $0, as: UTF8.self) }, "pk:sk")
            expectation.fulfill()
            return self.response(request.url!, status: 200, json: ["partialSuccess": [:]])
        }
        let trace = TraceClient(
            config: LangfuseConfig(baseURL: "https://langfuse.example", publicKey: "pk", secretKey: "sk"),
            session: mockSession())
        trace.record(.init(
            name: "decide", traceName: "granny.decision",
            input: ["url": "https://x.com"], output: ["action": "allow"],
            model: "m", startedAt: Date(), endedAt: Date()))
        await fulfillment(of: [expectation], timeout: 3)
    }

    // MARK: - Engine tier chain

    func testEngineUsesJevViaOpenRouterWhenLayaMissing() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: openRouterOK(
                #"{"action":"warn","message":"Từ từ đã cháu.","reason":"work-adjacent"}"#))
        }
        var config = GrannyConfig()
        config.openRouterKey = "or-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(url: "https://www.youtube.com/watch?v=x", title: "Lofi beats"),
            tasks: [], phase: .working)
        XCTAssertEqual(decision.source, "typesafe/jev-router")
        XCTAssertEqual(decision.action, .warn)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testEngineFallsThroughLayaJevToModelAndCaches() async {
        MockURLProtocol.handler = { [self] request in
            let url = request.url!.absoluteString
            if url.contains("laya.example") {
                return response(request.url!, status: 200, json: [
                    "answers": ["action": ["type": "choice", "choice": "allow", "answer_confidence": 0.1]],
                ])
            }
            if MockURLProtocol.requestCount == 2 {
                // Jev via OpenRouter fails: the engine must fall to DeepSeek.
                return response(request.url!, status: 500, json: ["error": "jev down"])
            }
            return response(request.url!, status: 200, json: openRouterOK(
                #"{"action":"block","message":"Ngoại cấm nhé.","reason":"entertainment"}"#))
        }
        var config = GrannyConfig()
        config.openRouterKey = "or-key"
        config.layaURL = "https://laya.example/v1"
        config.layaKey = "laya-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let url = "https://www.youtube.com/watch?v=lofi"

        let first = await engine.decide(url: url, title: "lofi", tasks: [], phase: .working)
        XCTAssertEqual(first.action, .block)
        XCTAssertEqual(first.source, "model")

        let requestsAfterFirst = MockURLProtocol.requestCount
        XCTAssertEqual(requestsAfterFirst, 3, "one laya attempt, one jev attempt, one model attempt")

        let second = await engine.decide(url: url, title: "lofi", tasks: [], phase: .working)
        XCTAssertEqual(second.action, .block)
        XCTAssertEqual(MockURLProtocol.requestCount, requestsAfterFirst, "cached verdict makes no new requests")
    }

    func testEngineUsesLayaWhenConfident() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: [
                "answers": ["action": ["type": "choice", "choice": "allow", "answer_confidence": 0.95]],
            ])
        }
        var config = GrannyConfig()
        config.layaURL = "https://laya.example/v1"
        config.layaKey = "laya-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            url: "https://www.youtube.com/watch?v=meditation", title: "thiền", tasks: [], phase: .working)
        XCTAssertEqual(decision.source, "laya")
        XCTAssertEqual(decision.action, .allow)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testEngineFillsGrannyLineForLayaVerdicts() async {
        GrannyLines.language = "vi"
        defer { GrannyLines.language = "en" }
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: [
                "answers": ["action": ["type": "choice", "choice": "block", "answer_confidence": 0.9]],
            ])
        }
        var config = GrannyConfig()
        config.layaURL = "https://laya.example/v1"
        config.layaKey = "laya-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(url: "https://www.youtube.com/watch?v=m", title: "Phim hành động"),
            tasks: [], phase: .working)
        XCTAssertEqual(decision.action, .block)
        XCTAssertEqual(decision.source, "laya")
        XCTAssertNotNil(decision.message)
        XCTAssertTrue(decision.message?.contains("Ngoại thấy cháu") ?? false)
    }

    func testEngineUnknownHostUsesLaya() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: [
                "answers": ["action": ["type": "choice", "choice": "warn", "answer_confidence": 0.8]],
            ])
        }
        var config = GrannyConfig()
        config.layaURL = "https://laya.example/v1"
        config.layaKey = "laya-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(url: "https://vnexpress.net/tin-tuc", title: "Tin tức"),
            tasks: [], phase: .working)
        XCTAssertEqual(decision.source, "laya")
        XCTAssertEqual(decision.action, .warn)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testEngineTracesRulesBlocksButNotAllows() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertTrue(request.url?.absoluteString.hasSuffix("/api/public/otel/v1/traces") ?? false)
            return self.response(request.url!, status: 200, json: ["partialSuccess": [:]])
        }
        let trace = TraceClient(
            config: LangfuseConfig(baseURL: "https://langfuse.example", publicKey: "pk", secretKey: "sk"),
            session: mockSession())
        let engine = DecisionEngine(config: GrannyConfig(), trace: trace, session: mockSession())

        _ = await engine.decide(url: "https://www.facebook.com/", title: nil, tasks: [], phase: .working)
        await engine.flushTraces()
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "rules block is traced")

        let task = TaskItem(title: "Apply 5 jobs", allowedSurfaces: ["linkedin.com/jobs*"])
        _ = await engine.decide(
            url: "https://www.linkedin.com/jobs/search", title: nil, tasks: [task], phase: .working)
        await engine.flushTraces()
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "rules allow stays untraced")
    }

    func testEngineTracesActions() async {
        MockURLProtocol.handler = { [self] request in
            return self.response(request.url!, status: 200, json: ["partialSuccess": [:]])
        }
        let trace = TraceClient(
            config: LangfuseConfig(baseURL: "https://langfuse.example", publicKey: "pk", secretKey: "sk"),
            session: mockSession())
        let engine = DecisionEngine(config: GrannyConfig(), trace: trace, session: mockSession())
        await engine.recordAction("tab-closed", input: ["urls": "https://www.facebook.com/"], output: ["count": "1"])
        await engine.flushTraces()
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "actions are traced")
    }

    func testEngineUsesJevWhenLayaMissing() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jev-key")
            return response(request.url!, status: 200, json: [
                "answers": ["action": ["type": "choice", "choice": "allow", "answer_confidence": 0.9]],
            ])
        }
        var config = GrannyConfig()
        config.jevURL = "https://jev.example/v1"
        config.jevKey = "jev-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(url: "https://www.youtube.com/watch?v=x", title: "Lofi beats"),
            tasks: [], phase: .working)
        XCTAssertEqual(decision.source, "jev")
        XCTAssertEqual(decision.action, .allow)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testEnginePrefersLayaOverJev() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer laya-key")
            return response(request.url!, status: 200, json: [
                "answers": ["action": ["type": "choice", "choice": "warn", "answer_confidence": 0.8]],
            ])
        }
        var config = GrannyConfig()
        config.layaURL = "https://laya.example/v1"
        config.layaKey = "laya-key"
        config.jevURL = "https://jev.example/v1"
        config.jevKey = "jev-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(url: "https://www.youtube.com/watch?v=x", title: "Lofi beats"),
            tasks: [], phase: .working)
        XCTAssertEqual(decision.source, "laya")
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testUpdateCheckerOverTheWire() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertTrue(request.url?.absoluteString.contains("api.github.com") ?? false)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "granny-agent")
            return response(request.url!, status: 200, json: [
                "tag_name": "v9.9.9",
                "html_url": "https://github.com/HappyVoxel/granny/releases/tag/v9.9.9",
            ])
        }
        let newer = await UpdateChecker.check(currentVersion: "0.1.0", session: mockSession())
        XCTAssertEqual(newer?.version, "9.9.9")

        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: [
                "tag_name": "v0.1.0",
                "html_url": "https://github.com/HappyVoxel/granny/releases/tag/v0.1.0",
            ])
        }
        let same = await UpdateChecker.check(currentVersion: "0.1.0", session: mockSession())
        XCTAssertNil(same)
    }

    func testEngineIntakeThroughModelTier() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: openRouterOK(
                #"{"tasks":[{"title":"a","purpose":"","surfaces":[]}],"question":""}"#))
        }
        var config = GrannyConfig()
        config.openRouterKey = "k"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let intake = await engine.parseIntake(text: "a")
        XCTAssertEqual(intake?.tasks.count, 1)
    }

    func testEngineIntakeWithoutKeyReturnsNil() async {
        let engine = DecisionEngine(config: GrannyConfig(), trace: TraceClient(config: nil), session: mockSession())
        let intake = await engine.parseIntake(text: "a")
        XCTAssertNil(intake)
    }
}
