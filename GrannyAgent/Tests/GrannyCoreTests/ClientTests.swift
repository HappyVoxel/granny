import XCTest
@testable import GrannyCore

final class ClientTests: XCTestCase {
    // MARK: - OpenRouter

    private func openRouterResponse(content: String) -> Data {
        let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testDecisionBodyCarriesSchemaAndContext() throws {
        let tasks = [TaskItem(title: "Apply 5 jobs", allowedSurfaces: ["linkedin.com/jobs*"])]
        let context = PageContext(
            url: "https://www.youtube.com/watch?v=abc",
            title: "Lo-fi beats to relax",
            channel: "Lofi Girl",
            description: "Chill beats to study to",
            kind: "video")
        let data = try XCTUnwrap(OpenRouterClient.decisionRequestBody(
            model: "deepseek/deepseek-v4.1-flash",
            context: context,
            tasks: tasks,
            phase: .working))
        let root = try XCTUnwrap(JSON.dict(from: data))
        XCTAssertEqual(root["model"] as? String, "deepseek/deepseek-v4.1-flash")
        let format = try XCTUnwrap(root["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        let user = try XCTUnwrap(messages[1]["content"] as? String)
        XCTAssertTrue(user.contains("youtube.com/watch"))
        XCTAssertTrue(user.contains("Lofi Girl"))
        XCTAssertTrue(user.contains("Chill beats to study to"))
        XCTAssertTrue(user.contains("Apply 5 jobs"))
        XCTAssertTrue(user.contains("working"))
    }

    func testStreakBodyFollowsLanguageAndStaysTiny() throws {
        let data = try XCTUnwrap(OpenRouterClient.streakRequestBody(
            model: OpenRouterClient.defaultStreakModel, kept: true, count: 3, language: "vi"))
        let body = try XCTUnwrap(JSON.dict(from: data))
        XCTAssertEqual(body["model"] as? String, "openrouter/free")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["enabled"] as? Bool, false,
                       "a streak line needs no chain of thought")
        XCTAssertEqual(body["max_tokens"] as? Int, 80, "a one-liner must not pay for an essay")
        let messages = body["messages"] as? [[String: Any]]
        let system = messages?.first?["content"] as? String
        XCTAssertTrue(system?.contains("Vietnamese") ?? false, "the line follows the set language")
        XCTAssertTrue(system?.contains("Ngoại") ?? false, "the persona is the language's")
    }

    func testParseTextResponse() throws {
        let payload: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": "  Ngoan lắm, mai cố thêm nhé.  "]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertEqual(OpenRouterClient.parseTextResponse(data), "Ngoan lắm, mai cố thêm nhé.")
        XCTAssertNil(OpenRouterClient.parseTextResponse(Data("{}".utf8)))
        XCTAssertNil(OpenRouterClient.parseTextResponse(Data(#"{"choices":[{"message":{"content":"  "}}]}"#.utf8)))
    }

    func testModelCallsDisableReasoning() throws {
        let data = try XCTUnwrap(OpenRouterClient.decisionRequestBody(
            model: "m", context: PageContext(url: "https://x.com"), tasks: [], phase: .working))
        let body = try XCTUnwrap(JSON.dict(from: data))
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["enabled"] as? Bool, false,
                       "a chain of thought is clock, not value, for a one-line verdict")
    }

    func testPlainDecisionBodyDropsSchemaAndSpellsOutJSON() throws {
        let data = try XCTUnwrap(OpenRouterClient.decisionRequestBody(
            model: "m", context: PageContext(url: "https://x.com"), tasks: [], phase: .working,
            structured: false))
        let body = try XCTUnwrap(JSON.dict(from: data))
        XCTAssertNil(body["response_format"], "the plain body must not ask for structured outputs")
        let messages = body["messages"] as? [[String: Any]]
        let system = messages?.first?["content"] as? String
        XCTAssertTrue(system?.contains("single JSON object") ?? false,
                      "without the schema the prompt itself must name the JSON shape")
    }

    func testDecisionPromptFollowsLanguage() throws {
        let context = PageContext(url: "https://www.youtube.com/watch?v=x", title: "Phim")

        let english = try XCTUnwrap(OpenRouterClient.decisionRequestBody(
            model: "m", context: context, tasks: [], phase: .working, language: "en"))
        let englishRoot = try XCTUnwrap(JSON.dict(from: english))
        let englishMessages = try XCTUnwrap(englishRoot["messages"] as? [[String: Any]])
        XCTAssertTrue((englishMessages[0]["content"] as? String)?.contains("English") ?? false)

        let vietnamese = try XCTUnwrap(OpenRouterClient.decisionRequestBody(
            model: "m", context: context, tasks: [], phase: .working, language: "vi"))
        let vietnameseRoot = try XCTUnwrap(JSON.dict(from: vietnamese))
        let vietnameseMessages = try XCTUnwrap(vietnameseRoot["messages"] as? [[String: Any]])
        XCTAssertTrue((vietnameseMessages[0]["content"] as? String)?.contains("Vietnamese") ?? false)
    }

    func testDecisionParsing() throws {
        let decision = OpenRouterClient.parseDecisionResponse(
            openRouterResponse(content: #"{"action":"warn","message":"Làm cho xong nhé cháu.","reason":"feed"}"#))
        XCTAssertEqual(decision?.action, .warn)
        XCTAssertEqual(decision?.source, "model")
        XCTAssertEqual(decision?.message, "Làm cho xong nhé cháu.")
    }

    func testDecisionParsingRejectsGarbage() {
        XCTAssertNil(OpenRouterClient.parseDecisionResponse(openRouterResponse(content: "not json")))
        XCTAssertNil(OpenRouterClient.parseDecisionResponse(openRouterResponse(content: #"{"action":"maybe"}"#)))
        XCTAssertNil(OpenRouterClient.parseDecisionResponse(Data("{}".utf8)))
    }

    func testIntakeParsing() throws {
        let intake = OpenRouterClient.parseIntakeResponse(openRouterResponse(content: """
            {"tasks":[{"title":"Học AI","purpose":"đọc blog","surfaces":["medium.com/*"]}],"question":"Học AI cụ thể là gì?"}
            """))
        XCTAssertEqual(intake?.tasks.count, 1)
        XCTAssertEqual(intake?.question, "Học AI cụ thể là gì?")
    }

    func testIntakeEmptyQuestionBecomesNil() throws {
        let intake = OpenRouterClient.parseIntakeResponse(openRouterResponse(content: """
            {"tasks":[{"title":"a","purpose":"","surfaces":[]}],"question":""}
            """))
        XCTAssertNotNil(intake)
        XCTAssertNil(intake?.question)
    }

    // MARK: - Laya

    private func layaResponse(choice: String, confidence: Double) -> Data {
        let body: [String: Any] = [
            "answers": ["action": ["type": "choice", "choice": choice, "answer_confidence": confidence]],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testLayaBodyPinsMultilingualForVietnamese() throws {
        let data = try XCTUnwrap(LayaClient.decisionRequestBody(
            language: "vi",
            context: PageContext(
                url: "https://www.youtube.com/watch?v=x",
                title: "phim hành động",
                channel: "Cinema",
                kind: "video"),
            tasks: [TaskItem(title: "Viết docs")],
            phase: .working))
        let root = try XCTUnwrap(JSON.dict(from: data))
        XCTAssertEqual(root["model"] as? String, "multilingual")
        let questions = try XCTUnwrap(root["questions"] as? [String: Any])
        XCTAssertNotNil(questions["action"])
        let state = try XCTUnwrap(root["state"] as? [String: Any])
        XCTAssertEqual(state["channel"] as? String, "Cinema")
        XCTAssertEqual(state["kind"] as? String, "video")
        let action = try XCTUnwrap(questions["action"] as? [String: Any])
        let criteria = try XCTUnwrap(action["criteria"] as? [String: String])
        XCTAssertTrue(criteria["allow"]?.contains("unmistakably music") ?? false)
        XCTAssertTrue(criteria["warn"]?.contains("ambiguous") ?? false)
        XCTAssertTrue(criteria["allow"]?.contains("Perplexity") ?? false)
    }

    func testLayaBodyLeavesEnglishUnpinned() throws {
        let data = try XCTUnwrap(LayaClient.decisionRequestBody(
            language: "en",
            context: PageContext(url: "https://example.com"),
            tasks: [],
            phase: .working))
        let root = try XCTUnwrap(JSON.dict(from: data))
        XCTAssertNil(root["model"])
    }

    func testLayaBodyPinsMultilingualForEveryNonEnglishLanguage() throws {
        for language in ["vi", "fi", "de"] {
            let data = try XCTUnwrap(LayaClient.decisionRequestBody(
                language: language,
                context: PageContext(url: "https://example.com"),
                tasks: [],
                phase: .working))
            let root = try XCTUnwrap(JSON.dict(from: data))
            XCTAssertEqual(root["model"] as? String, "multilingual", language)
        }
    }

    func testLayaConfidenceGate() {
        XCTAssertEqual(LayaClient.parseResponse(layaResponse(choice: "block", confidence: 0.9))?.action, .block)
        XCTAssertNil(LayaClient.parseResponse(layaResponse(choice: "block", confidence: 0.4)))
        XCTAssertNil(LayaClient.parseResponse(layaResponse(choice: "nonsense", confidence: 0.9)))
    }

    /// The free Zaitlabs deployment answers `confidence` where the OpsCom
    /// console answers `answer_confidence`; both gate the same way, and the
    /// gate itself is adjustable per host.
    func testLayaAcceptsBothConfidenceFieldNames() throws {
        let zaitlabs = Data(#"{"answers":{"action":{"type":"choice","choice":"block","confidence":0.9}}}"#.utf8)
        XCTAssertEqual(LayaClient.parseResponse(zaitlabs)?.action, .block)
        let low = Data(#"{"answers":{"action":{"type":"choice","choice":"block","confidence":0.2}}}"#.utf8)
        XCTAssertNil(LayaClient.parseResponse(low))
        XCTAssertEqual(LayaClient.parseResponse(low, gate: 0.1)?.action, .block)
    }

    func testLayaEndpointAcceptsBaseOrFullURL() {
        XCTAssertEqual(
            LayaClient.endpointURL(from: "https://laya.example/v1")?.absoluteString,
            "https://laya.example/v1/systemone")
        XCTAssertEqual(
            LayaClient.endpointURL(from: "https://laya.example/v1/")?.absoluteString,
            "https://laya.example/v1/systemone")
        XCTAssertEqual(
            LayaClient.endpointURL(from: "https://console.opscom.io/v1/systemone")?.absoluteString,
            "https://console.opscom.io/v1/systemone")
        XCTAssertEqual(
            LayaClient.endpointURL(from: "https://laya.example")?.absoluteString,
            "https://laya.example/systemone")
        XCTAssertNil(LayaClient.endpointURL(from: "not a url"))
        XCTAssertNil(LayaClient.endpointURL(from: "ftp://laya.example"))
    }

    func testLayaBodyLetsAConfiguredModelWin() throws {
        let data = try XCTUnwrap(LayaClient.decisionRequestBody(
            language: "vi",
            context: PageContext(url: "https://example.com"),
            tasks: [],
            phase: .working,
            model: "laya/typed-decisions"))
        let root = try XCTUnwrap(JSON.dict(from: data))
        XCTAssertEqual(root["model"] as? String, "laya/typed-decisions")
    }

    // MARK: - Trace

    func testTraceOTLPBodyShape() throws {
        let span = TraceClient.Span(
            name: "decide",
            traceName: "granny.decision",
            input: ["url": "https://example.com"],
            output: ["action": "allow"],
            model: "deepseek/deepseek-v4.1-flash",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_001))
        let data = try XCTUnwrap(TraceClient.otlpBody(span: span))
        let root = try XCTUnwrap(JSON.dict(from: data))
        let resourceSpans = try XCTUnwrap(root["resourceSpans"] as? [[String: Any]])
        let scopeSpans = try XCTUnwrap(resourceSpans[0]["scopeSpans"] as? [[String: Any]])
        let spans = try XCTUnwrap(scopeSpans[0]["spans"] as? [[String: Any]])
        let otlpSpan = spans[0]
        XCTAssertEqual(otlpSpan["name"] as? String, "decide")
        XCTAssertEqual((otlpSpan["traceId"] as? String)?.count, 32)
        XCTAssertEqual((otlpSpan["spanId"] as? String)?.count, 16)
        XCTAssertEqual(otlpSpan["startTimeUnixNano"] as? String, "1700000000000000000")

        let attributes = try XCTUnwrap(otlpSpan["attributes"] as? [[String: Any]])
        let byKey = Dictionary(uniqueKeysWithValues: attributes.compactMap { attr -> (String, String)? in
            guard let key = attr["key"] as? String,
                  let value = attr["value"] as? [String: String],
                  let stringValue = value["stringValue"] else { return nil }
            return (key, stringValue)
        })
        XCTAssertEqual(byKey["langfuse.trace.name"], "granny.decision")
        XCTAssertEqual(byKey["langfuse.observation.type"], "generation")
        XCTAssertEqual(byKey["langfuse.observation.model.name"], "deepseek/deepseek-v4.1-flash")
        XCTAssertTrue(byKey["langfuse.observation.input"]?.contains("example.com") ?? false)
    }

    func testTraceOTLPBodySpanWithoutModel() throws {
        let span = TraceClient.Span(
            name: "tab-closed",
            traceName: "granny.action",
            input: ["urls": "https://www.facebook.com/"],
            output: ["count": "1"],
            model: nil,
            startedAt: Date(),
            endedAt: Date())
        let data = try XCTUnwrap(TraceClient.otlpBody(span: span))
        let root = try XCTUnwrap(JSON.dict(from: data))
        let resourceSpans = try XCTUnwrap(root["resourceSpans"] as? [[String: Any]])
        let scopeSpans = try XCTUnwrap(resourceSpans[0]["scopeSpans"] as? [[String: Any]])
        let spans = try XCTUnwrap(scopeSpans[0]["spans"] as? [[String: Any]])
        let attributes = try XCTUnwrap(spans[0]["attributes"] as? [[String: Any]])
        let keys = attributes.compactMap { $0["key"] as? String }
        XCTAssertFalse(keys.contains("langfuse.observation.model.name"))
        let typeAttribute = attributes.first { ($0["key"] as? String) == "langfuse.observation.type" }
        let value = (typeAttribute?["value"] as? [String: String])?["stringValue"]
        XCTAssertEqual(value, "span")
    }

    func testTraceDisabledWithoutConfig() {
        XCTAssertFalse(TraceClient(config: nil).isEnabled)
        XCTAssertTrue(TraceClient(config: LangfuseConfig(baseURL: "https://x", publicKey: "p", secretKey: "s")).isEnabled)
    }
}

extension ClientTests {
    func testIntakePromptFollowsLanguage() {
        XCTAssertTrue(OpenRouterClient.intakeSystemPrompt(language: "vi").contains("Vietnamese"))
        XCTAssertTrue(OpenRouterClient.intakeSystemPrompt(language: "fi").contains("Finnish"))
        let en = OpenRouterClient.intakeSystemPrompt(language: "en")
        XCTAssertTrue(en.contains("English"))
        XCTAssertFalse(en.contains("Ngoại"))
    }
}
