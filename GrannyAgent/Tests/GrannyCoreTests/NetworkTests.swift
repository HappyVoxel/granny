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

    /// A provider that cannot honour structured outputs answers 400; the
    /// plain body retries once and still parses.
    func testStructuredOutputRejectionRetriesOnce() async {
        MockURLProtocol.handler = { [self] request in
            if MockURLProtocol.requestCount == 1 {
                return response(request.url!, status: 400, json: ["error": "model features structured outputs not support"])
            }
            return response(request.url!, status: 200, json: openRouterOK(
                #"{"action":"warn","message":"Careful, dear.","reason":"entertainment"}"#))
        }
        let client = OpenRouterClient(settings: .init(apiKey: "k", model: "m"), session: mockSession())
        let decision = await client.decide(url: "https://x.com/", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(decision?.action, .warn)
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "the 400 on the schema body retries the plain one")
    }

    func testAuthFailureDoesNotRetry() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 401, json: ["error": "bad key"])
        }
        let client = OpenRouterClient(settings: .init(apiKey: "k", model: "m"), session: mockSession())
        let decision = await client.decide(url: "https://x.com/", title: nil, tasks: [], phase: .working)
        XCTAssertNil(decision)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    /// A 400 that is not about structured outputs (bad model, malformed
    /// request) fails open without a second round trip.
    func testUnrelated400DoesNotRetry() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 400, json: ["error": ["message": "invalid model id"]])
        }
        let client = OpenRouterClient(settings: .init(apiKey: "k", model: "m"), session: mockSession())
        let decision = await client.decide(url: "https://x.com/", title: nil, tasks: [], phase: .working)
        XCTAssertNil(decision)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "only the structured-outputs complaint retries")
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

    /// A bare host resolves through the console's /v1 shape: 404 on the
    /// typed path, then the answer - and the found endpoint is remembered.
    func testLayaBareBaseFallsBackToV1AndRemembers() async {
        MockURLProtocol.handler = { [self] request in
            let path = request.url?.path ?? ""
            if path == "/v1/systemone" {
                return response(request.url!, status: 200, json: [
                    "answers": ["action": ["type": "choice", "choice": "warn", "answer_confidence": 0.9]],
                ])
            }
            return response(request.url!, status: 404, json: ["error": "not here"])
        }
        let client = LayaClient(baseURL: "https://console.opscom.io", apiKey: "k", session: mockSession())

        let first = await client.decide(url: "https://linkedin.com/feed", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(first?.action, .warn)
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "one 404, then the /v1 answer")

        let second = await client.decide(url: "https://x.com/feed", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(second?.action, .warn)
        XCTAssertEqual(MockURLProtocol.requestCount, 3, "the resolved endpoint is remembered")
    }

    func testLayaBareBase404EverywhereFails() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 404, json: ["error": "not here"])
        }
        let client = LayaClient(baseURL: "https://console.opscom.io", apiKey: "k", session: mockSession())
        let decision = await client.decide(url: "https://linkedin.com/feed", title: nil, tasks: [], phase: .working)
        XCTAssertNil(decision)
        XCTAssertEqual(MockURLProtocol.requestCount, 3, "all three candidates were tried")
    }

    /// The free Zaitlabs deployment takes no key; the client must not send
    /// an Authorization header on keyless hosts.
    func testLayaKeylessHostOmitsAuthorization() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.absoluteString, "https://laya.inference.zaitlabs.com/v1/systemone")
            return response(request.url!, status: 200, json: [
                "answers": ["action": ["type": "choice", "choice": "allow", "answer_confidence": 0.9]],
            ])
        }
        let client = LayaClient(
            baseURL: "https://laya.inference.zaitlabs.com/v1",
            apiKey: "",
            session: mockSession())
        let decision = await client.decide(url: "https://linkedin.com/feed", title: nil, tasks: [], phase: .working)
        XCTAssertEqual(decision?.action, .allow)
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
            context: PageContext(url: "https://www.youtube.com/watch?v=x", title: "Interstellar - Official Trailer"),
            tasks: [], phase: .working)
        XCTAssertEqual(decision.source, "typesafe/jev-router")
        XCTAssertEqual(decision.action, .warn)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testEngineLetsFocusAudioPass() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: openRouterOK(
                #"{"action":"warn","message":"Từ từ đã cháu.","reason":"manifestation video"}"#))
        }
        var config = GrannyConfig()
        config.openRouterKey = "or-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(
                url: "https://www.youtube.com/watch?v=pmq45EPNGqE",
                title: "You Will Become Super RICH | Attract Wealth in 5 Minutes ~ 888Hz",
                channel: "Golden Aura Frequencies",
                kind: "video"),
            tasks: [], phase: .working)
        XCTAssertEqual(decision.action, .allow, "focus audio is music to work by")
        XCTAssertEqual(decision.reason, "focus audio: compatible with work")
    }

    func testFocusAudioSignals() {
        XCTAssertTrue(DecisionEngine.isFocusAudio(PageContext(
            url: "u", title: "8Hz 528 Hz ABUNDANCE FREQUENCY", channel: "Golden Aura Frequencies")))
        XCTAssertTrue(DecisionEngine.isFocusAudio(PageContext(url: "u", title: "lofi hip hop radio")))
        XCTAssertTrue(DecisionEngine.isFocusAudio(PageContext(url: "u", title: "Rain sounds for sleep")))
        XCTAssertFalse(DecisionEngine.isFocusAudio(PageContext(
            url: "u", title: "MrBeast 24 hours challenge")))
        XCTAssertFalse(DecisionEngine.isFocusAudio(PageContext(url: "u", title: "Interstellar trailer")))
    }

    func testRulesLevelWarnIsRelievedForFocusAudio() async {
        // A task surface on YouTube: the video outside it warns in the rules
        // tier, before any model runs. Focus audio must not nag even there.
        let task = TaskItem(title: "Watch the lecture", allowedSurfaces: ["youtube.com/watch?v=abc"])
        let engine = DecisionEngine(config: GrannyConfig(), trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(
                url: "https://www.youtube.com/watch?v=zzz",
                title: "lofi hip hop radio - beats to relax/study to",
                kind: "video"),
            tasks: [task], phase: .working)
        XCTAssertEqual(decision.action, .allow)
        XCTAssertEqual(decision.reason, "focus audio: compatible with work")
        XCTAssertEqual(decision.source, "rules")
    }

    /// Past bedtime granny's own line replaces the model's; the verdict and
    /// the reason stay the content's.
    func testEngineSpeaksBedtimeAtNight() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: openRouterOK(
                #"{"action":"warn","message":"Carry on only if it really helps.","reason":"entertainment"}"#))
        }
        var config = GrannyConfig()
        config.openRouterKey = "or-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())

        let night = await engine.decide(url: "https://example.com/feed", title: "Feed", tasks: [], phase: .night)
        XCTAssertEqual(night.action, .warn)
        XCTAssertEqual(night.message, GrannyLines.sleepNag)
        XCTAssertEqual(night.reason, "entertainment", "the reason still says what the page is")

        let day = await engine.decide(url: "https://example.com/feed2", title: "Feed", tasks: [], phase: .working)
        XCTAssertEqual(day.message, "Carry on only if it really helps.")
    }

    /// Rules-level blocks speak bedtime too - the voice is the phase's, not
    /// the tier's.
    func testRulesBlockSpeaksBedtimeAtNight() async {
        let engine = DecisionEngine(config: GrannyConfig(), trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(url: "https://www.facebook.com/feed", title: nil, tasks: [], phase: .night)
        XCTAssertEqual(decision.action, .block)
        XCTAssertEqual(decision.message, GrannyLines.sleepNag)
    }

    /// The forced-context warning (unreadable YouTube after the retry) is a
    /// warn from the context tier, so bedtime applies there too.
    func testForcedContextWarningSpeaksBedtimeAtNight() async {
        let engine = DecisionEngine(config: GrannyConfig(), trace: TraceClient(config: nil), session: mockSession())
        let context = PageContext(url: "https://www.youtube.com/watch?v=x", title: nil)

        let night = await engine.decide(context: context, tasks: [], phase: .night, force: true)
        XCTAssertEqual(night.action, .warn)
        XCTAssertEqual(night.message, GrannyLines.sleepNag)

        let day = await engine.decide(context: context, tasks: [], phase: .working, force: true)
        XCTAssertEqual(day.action, .warn)
        XCTAssertNotEqual(day.message, GrannyLines.sleepNag)
    }

    /// The streak line rides the free router and parses as plain text.
    func testEngineStreakLineUsesTheFreeRouter() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: [
                "choices": [["message": ["role": "assistant", "content": "Ngoan lắm, mai cố thêm nhé."]]],
            ])
        }
        var config = GrannyConfig()
        config.openRouterKey = "or-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let line = await engine.streakLine(kept: true, count: 3)
        XCTAssertEqual(line, "Ngoan lắm, mai cố thêm nhé.")
    }

    func testEngineStreakLineFailsQuietly() async {
        let engine = DecisionEngine(config: GrannyConfig(), trace: TraceClient(config: nil), session: mockSession())
        let line = await engine.streakLine(kept: true, count: 3)
        XCTAssertNil(line, "no key: the caller keeps its template")
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "and no request leaves the machine")
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

    func testEngineGenericYouTubeTitleNeedsContext() async {
        var config = GrannyConfig()
        config.openRouterKey = "or-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(url: "https://www.youtube.com/watch?v=x", title: "YouTube", kind: "video"),
            tasks: [], phase: .working)
        XCTAssertEqual(decision.action, .needContext)
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "a placeholder title never reaches a tier")
    }

    func testEngineDeepReadsYouTubeVideoBeforeFastTiers() async {
        MockURLProtocol.handler = { [self] request in
            XCTAssertTrue(request.url?.absoluteString.contains("openrouter.ai") ?? false)
            return response(request.url!, status: 200, json: openRouterOK(
                #"{"action":"warn","message":"Phim này chưa khớp việc đang làm.","reason":"long-form video"}"#))
        }
        var config = GrannyConfig()
        config.openRouterKey = "or-key"
        config.layaURL = "https://laya.example/v1"
        config.layaKey = "laya-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(
                url: "https://www.youtube.com/watch?v=movie",
                title: "Phim Lẻ Hay: THÁNH BÀI - YouTube",
                channel: "KK Studio",
                kind: "video"),
            tasks: [TaskItem(title: "Create data pipeline")], phase: .working)
        XCTAssertEqual(decision.source, "model")
        XCTAssertEqual(decision.action, .warn)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "the deep read skips the fast tiers")
    }

    func testEngineForcedWeakContextOnYouTubeWarns() async {
        let engine = DecisionEngine(config: GrannyConfig(), trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(url: "https://www.youtube.com/watch?v=x", title: "YouTube", kind: "video"),
            tasks: [TaskItem(title: "Create data pipeline")], phase: .working, force: true)
        XCTAssertEqual(decision.action, .warn, "an unreadable page must not be allowed")
        XCTAssertEqual(decision.source, "context")
        XCTAssertTrue(decision.message?.contains("YouTube") ?? false)
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "no tier is asked about a page nobody can read")
    }

    func testEngineDemotesYouTubeBrowsingSurfacesToWarn() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: openRouterOK(
                #"{"action":"block","message":"That front page is a feed of distractions.","reason":"feed"}"#))
        }
        var config = GrannyConfig()
        config.openRouterKey = "or-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(url: "https://www.youtube.com/", title: "Home - YouTube", kind: "youtube"),
            tasks: [TaskItem(title: "Create data pipeline")], phase: .working, force: true)
        XCTAssertEqual(decision.action, .warn, "a browsing surface is negotiable, never a dead end")
        XCTAssertTrue(decision.message?.contains("distractions") ?? false)
    }

    func testEngineDoesNotCacheVerdictsFromEmptyContext() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: openRouterOK(
                #"{"action":"allow","message":"ok","reason":"video"}"#))
        }
        var config = GrannyConfig()
        config.openRouterKey = "or-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let context = PageContext(url: "https://www.netflix.com/browse")
        _ = await engine.decide(context: context, tasks: [], phase: .working, force: true)
        _ = await engine.decide(context: context, tasks: [], phase: .working, force: true)
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "a verdict without a content signal is not cached")
    }

    func testEngineNegotiableLineNamesContentNotTaskJargon() async {
        GrannyLines.language = "vi"
        defer { GrannyLines.language = "en" }
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: [
                "answers": ["action": ["type": "choice", "choice": "warn", "answer_confidence": 0.9]],
            ])
        }
        var config = GrannyConfig()
        config.layaURL = "https://laya.example/v1"
        config.layaKey = "laya-key"
        let engine = DecisionEngine(config: config, trace: TraceClient(config: nil), session: mockSession())
        let decision = await engine.decide(
            context: PageContext(url: "https://www.youtube.com/watch?v=v", title: "Mùi Phở - Review", kind: "video"),
            tasks: [TaskItem(title: "Learn Hugging Face certificate")],
            phase: .working)
        XCTAssertEqual(decision.action, .warn)
        XCTAssertTrue(decision.message?.contains("Mùi Phở") ?? false)
        XCTAssertFalse(decision.message?.contains("Hugging Face") ?? true, "task jargon stays out of granny's line")
    }

    func testLayaDetailedReportsMissReasons() async {
        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 200, json: [
                "answers": ["action": ["type": "choice", "choice": "block", "answer_confidence": 0.2]],
            ])
        }
        let client = LayaClient(baseURL: "https://laya.example/v1", apiKey: "k", session: mockSession())
        let low = await client.decideDetailed(context: PageContext(url: "https://x.com"), tasks: [], phase: .working)
        XCTAssertNil(low.decision)
        XCTAssertEqual(low.miss, "low confidence 0.20")

        MockURLProtocol.handler = { [self] request in
            response(request.url!, status: 403, json: ["error": "forbidden"])
        }
        let forbidden = await client.decideDetailed(
            context: PageContext(url: "https://x.com"), tasks: [], phase: .working)
        XCTAssertNil(forbidden.decision)
        XCTAssertEqual(forbidden.miss, "http 403")
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
