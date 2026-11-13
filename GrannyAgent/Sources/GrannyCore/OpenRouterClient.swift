import Foundation

public struct LLMSettings: Sendable {
    public var apiKey: String
    public var model: String
    public var timeout: TimeInterval
    /// Granny's speaking language: "en" (default), "vi" or "fi".
    public var language: String

    public init(apiKey: String, model: String, timeout: TimeInterval = 8, language: String = "en") {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.language = language
    }
}

public struct OpenRouterClient: Sendable {
    let settings: LLMSettings
    let session: URLSession
    /// Verdict label: "model" for the DeepSeek fallback, the model slug for
    /// Jev-via-OpenRouter.
    let source: String
    private static let defaultEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static var endpoint: URL {
        if let raw = ProcessInfo.processInfo.environment[GrannyEnv.openRouterURL],
           !raw.isEmpty,
           let url = URL(string: raw)
        {
            return url
        }
        return defaultEndpoint
    }
    static let streamTimeout: TimeInterval = 60

    public init(settings: LLMSettings, source: String = "model", session: URLSession = .shared) {
        self.settings = settings
        self.source = source
        self.session = session
    }

    /// Picks the configured model slug for a `model.stream` tier request.
    public static func resolveModel(tier: String?, config: GrannyConfig) -> String {
        switch tier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fast", "jev":
            let jev = config.jevModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return jev.isEmpty ? config.model : jev
        case "free", "streak":
            let streak = config.streakModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return streak.isEmpty ? defaultStreakModel : streak
        default:
            return config.model
        }
    }

    /// Streams one chat-completions turn for `model.stream`, emitting text
    /// deltas as they arrive and returning assembled tool calls + token usage.
    /// Retries once on transient transport/429/5xx errors before any delta is
    /// emitted; never retries after a delta has already gone over the wire.
    public func streamChat(
        messages: [EngineJSON],
        tools: [EngineJSON]? = nil,
        reasoning: Bool = false,
        onDelta: @Sendable (String) -> Void
    ) async -> Result<ModelStreamDone, EngineError> {
        guard let body = Self.modelStreamRequestBody(
            model: settings.model, messages: messages, tools: tools, reasoning: reasoning)
        else {
            return .failure(.invalid("invalid model.stream messages or tools"))
        }
        let timeout = max(settings.timeout, Self.streamTimeout)
        let first = await performStreamOnce(body: body, timeout: timeout, onDelta: onDelta)
        switch first {
        case .success(let done):
            return .success(done)
        case .failure(let failure):
            guard failure.canRetry, !Task.isCancelled else {
                return .failure(failure.error)
            }
            let second = await performStreamOnce(body: body, timeout: timeout, onDelta: onDelta)
            switch second {
            case .success(let done):
                return .success(done)
            case .failure(let retryFailure):
                return .failure(retryFailure.error)
            }
        }
    }

    private struct StreamAttemptFailure: Error {
        let error: EngineError
        let canRetry: Bool
    }

    private struct PartialToolCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    private func performStreamOnce(
        body: Data,
        timeout: TimeInterval,
        onDelta: @Sendable (String) -> Void
    ) async -> Result<ModelStreamDone, StreamAttemptFailure> {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var emittedAnyDelta = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.init(
                    error: EngineError(code: .internal, reason: "non-HTTP model response"),
                    canRetry: true))
            }
            guard http.statusCode == 200 else {
                var errLines: [String] = []
                for try await line in bytes.lines {
                    errLines.append(line)
                    if errLines.count >= 8 { break }
                }
                let detail = errLines.joined(separator: " ").prefix(200)
                let transient = http.statusCode == 429 || (500...599).contains(http.statusCode)
                return .failure(.init(
                    error: EngineError(
                        code: .internal,
                        reason: detail.isEmpty
                            ? "model HTTP \(http.statusCode)"
                            : "model HTTP \(http.statusCode): \(detail)"),
                    canRetry: transient))
            }

            var fullText = ""
            var usageIn = 0
            var usageOut = 0
            var toolCallsByIndex: [Int: PartialToolCall] = [:]
            var sawSSE = false
            var plainLines: [String] = []

            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix(":") { continue }
                guard trimmed.hasPrefix("data:") else {
                    if !sawSSE { plainLines.append(trimmed) }
                    continue
                }
                sawSSE = true
                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let chunkData = payload.data(using: .utf8),
                      let dict = JSON.dict(from: chunkData)
                else { continue }

                if let errObj = dict["error"] as? [String: Any],
                   let message = errObj["message"] as? String
                {
                    return .failure(.init(
                        error: EngineError(code: .internal, reason: message),
                        canRetry: !emittedAnyDelta))
                }
                Self.consumeChunk(
                    dict,
                    fullText: &fullText,
                    toolCallsByIndex: &toolCallsByIndex,
                    usageIn: &usageIn,
                    usageOut: &usageOut,
                    onDelta: { piece in
                        emittedAnyDelta = true
                        onDelta(piece)
                    })
            }

            // Fallback when an upstream ignores `stream: true` and returns one JSON body.
            if !sawSSE, !plainLines.isEmpty,
               let data = plainLines.joined(separator: "\n").data(using: .utf8),
               let dict = JSON.dict(from: data)
            {
                Self.consumeChunk(
                    dict,
                    fullText: &fullText,
                    toolCallsByIndex: &toolCallsByIndex,
                    usageIn: &usageIn,
                    usageOut: &usageOut,
                    onDelta: { piece in
                        emittedAnyDelta = true
                        onDelta(piece)
                    })
            }

            let orderedCalls = toolCallsByIndex.keys.sorted().compactMap { index -> ModelToolCall? in
                guard let item = toolCallsByIndex[index], !item.name.isEmpty else { return nil }
                let callID = item.id.isEmpty ? "call_\(index)" : item.id
                return ModelToolCall(id: callID, name: item.name, arguments: item.arguments)
            }
            if fullText.isEmpty, orderedCalls.isEmpty {
                return .failure(.init(
                    error: EngineError(code: .internal, reason: "model stream produced no content"),
                    canRetry: !emittedAnyDelta))
            }
            return .success(ModelStreamDone(
                text: fullText,
                toolCalls: orderedCalls,
                usage: ModelUsage(inTokens: usageIn, outTokens: usageOut)))
        } catch is CancellationError {
            return .failure(.init(
                error: EngineError(code: .internal, reason: "model.stream cancelled"),
                canRetry: false))
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .failure(.init(
                error: EngineError(code: .internal, reason: "model.stream cancelled"),
                canRetry: false))
        } catch {
            return .failure(.init(
                error: EngineError(
                    code: .internal,
                    reason: "model transport failed: \(error.localizedDescription)"),
                canRetry: !emittedAnyDelta))
        }
    }

    private static func consumeChunk(
        _ dict: [String: Any],
        fullText: inout String,
        toolCallsByIndex: inout [Int: PartialToolCall],
        usageIn: inout Int,
        usageOut: inout Int,
        onDelta: (String) -> Void
    ) {
        if let usage = dict["usage"] as? [String: Any] {
            if let prompt = usage["prompt_tokens"] as? Int { usageIn = prompt }
            if let completion = usage["completion_tokens"] as? Int { usageOut = completion }
        }
        guard let choices = dict["choices"] as? [[String: Any]],
              let first = choices.first
        else { return }
        let carrier = (first["delta"] as? [String: Any]) ?? (first["message"] as? [String: Any])
        guard let carrier else { return }

        if let content = carrier["content"] as? String, !content.isEmpty {
            fullText += content
            onDelta(content)
        }
        if let rawCalls = carrier["tool_calls"] as? [[String: Any]] {
            for (offset, call) in rawCalls.enumerated() {
                let index = (call["index"] as? Int) ?? offset
                var entry = toolCallsByIndex[index] ?? PartialToolCall()
                if let id = call["id"] as? String, !id.isEmpty {
                    entry.id = id
                }
                if let fn = call["function"] as? [String: Any] {
                    if let name = fn["name"] as? String, !name.isEmpty, entry.name.isEmpty {
                        entry.name = name
                    }
                    if let args = fn["arguments"] as? String {
                        entry.arguments += args
                    }
                }
                toolCallsByIndex[index] = entry
            }
        }
    }

    public static func modelStreamRequestBody(
        model: String,
        messages: [EngineJSON],
        tools: [EngineJSON]? = nil,
        reasoning: Bool = false
    ) -> Data? {
        guard !messages.isEmpty else { return nil }
        var wireMessages: [[String: Any]] = []
        for entry in messages {
            guard case .object(let fields) = entry,
                  case .string(let rawRole) = fields["role"]
            else { return nil }
            let role = rawRole.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !role.isEmpty else { return nil }

            var message: [String: Any] = ["role": role]
            let rawCalls = fields["tool_calls"] ?? fields["toolCalls"]
            if let content = fields["content"] {
                message["content"] = anyJSONValue(content)
            } else if rawCalls != nil, role == "assistant" {
                message["content"] = NSNull()
            } else {
                return nil
            }
            if case .string(let name) = fields["name"], !name.isEmpty {
                message["name"] = name
            }
            if case .string(let callID) = fields["tool_call_id"] ?? fields["toolCallID"], !callID.isEmpty {
                message["tool_call_id"] = callID
            }
            if case .array(let calls) = rawCalls {
                var normalizedCalls: [[String: Any]] = []
                for (offset, item) in calls.enumerated() {
                    guard case .object(let callFields) = item else { return nil }
                    let fnSource: [String: EngineJSON]
                    if case .object(let nestedFn) = callFields["function"] {
                        fnSource = nestedFn
                    } else {
                        fnSource = callFields
                    }
                    guard case .string(let fnName) = fnSource["name"], !fnName.isEmpty else {
                        return nil
                    }
                    let callID: String
                    if case .string(let id) = callFields["id"], !id.isEmpty {
                        callID = id
                    } else {
                        callID = "call_\(offset)"
                    }
                    let args: String
                    if case .string(let rawArgs) = fnSource["arguments"] {
                        args = rawArgs
                    } else if let argVal = fnSource["arguments"], argVal != .null,
                              let encoded = try? JSONEncoder.engine.encode(argVal),
                              let text = String(data: encoded, encoding: .utf8)
                    {
                        args = text
                    } else {
                        args = "{}"
                    }
                    normalizedCalls.append([
                        "id": callID,
                        "type": "function",
                        "function": ["name": fnName, "arguments": args],
                    ])
                }
                message["tool_calls"] = normalizedCalls
            }
            wireMessages.append(message)
        }

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "reasoning": ["enabled": reasoning],
            "messages": wireMessages,
        ]
        if let tools, !tools.isEmpty {
            var wireTools: [[String: Any]] = []
            for tool in tools {
                guard case .object(let fields) = tool else { return nil }
                if fields["type"] == .string("function"),
                   case .object = fields["function"],
                   let converted = anyJSONValue(tool) as? [String: Any]
                {
                    wireTools.append(converted)
                } else if case .string(let name) = fields["name"], !name.isEmpty {
                    var fn: [String: Any] = ["name": name]
                    if case .string(let desc) = fields["description"] {
                        fn["description"] = desc
                    }
                    if let params = fields["parameters"] {
                        fn["parameters"] = anyJSONValue(params)
                    } else {
                        fn["parameters"] = ["type": "object", "properties": [String: Any]()]
                    }
                    wireTools.append(["type": "function", "function": fn])
                } else {
                    return nil
                }
            }
            body["tools"] = wireTools
        }
        return JSON.data(from: body)
    }

    private static func anyJSONValue(_ value: EngineJSON) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { return Int(n) }
            return n
        case .string(let s): return s
        case .array(let items): return items.map(anyJSONValue)
        case .object(let map): return map.mapValues(anyJSONValue)
        }
    }

    /// Ambiguous-URL verdict. nil on any failure; the engine falls through.
    public func decide(url: String, title: String?, tasks: [TaskItem], phase: Phase) async -> Decision? {
        await decide(context: PageContext(url: url, title: title), tasks: tasks, phase: phase)
    }

    public func decide(context: PageContext, tasks: [TaskItem], phase: Phase) async -> Decision? {
        guard let strict = Self.decisionRequestBody(
            model: settings.model, context: context, tasks: tasks, phase: phase, language: settings.language
        ), let plain = Self.decisionRequestBody(
            model: settings.model, context: context, tasks: tasks, phase: phase,
            language: settings.language, structured: false
        ) else { return nil }
        guard let data = await post(strict, plainFallback: plain, timeout: settings.timeout) else { return nil }
        return Self.parseDecisionResponse(data, source: source)
    }

    /// Intake pass: refine tasks and ask one clarifying question if the
    /// list is vague. nil on any failure; the caller keeps the naive parse.
    /// A user-initiated one-off deserves patience: a reasoning model can
    /// think past the verdict timeout, so intake gets its own, longer one.
    public func parseIntake(text: String) async -> ParsedIntake? {
        guard let strict = Self.intakeRequestBody(
            model: settings.model, text: text, language: settings.language),
            let plain = Self.intakeRequestBody(
                model: settings.model, text: text, language: settings.language, structured: false)
        else { return nil }
        let timeout = max(settings.timeout, Self.intakeTimeout)
        guard let data = await post(strict, plainFallback: plain, timeout: timeout) else { return nil }
        return Self.parseIntakeResponse(data)
    }

    /// The intake request's own budget, independent of the verdict timeout.
    static let intakeTimeout: TimeInterval = 30

    /// A cheap model for the streak line: the free router picks whatever
    /// free endpoint is up, so the line never depends on one provider.
    /// Overridable with `streakModel` in the config.
    public static let defaultStreakModel = "openrouter/free"

    /// One short encouraging line from granny, in the configured language.
    /// Plain text, tiny budget, no structured outputs and no reasoning: the
    /// caller keeps its own template on any failure. The deadline is short
    /// on purpose - a notification must not wait on a slow free endpoint.
    public func streakLine(kept: Bool, count: Int, model: String) async -> String? {
        guard let body = Self.streakRequestBody(
            model: model, kept: kept, count: count, language: settings.language)
        else { return nil }
        let response = await perform(body, timeout: Self.streakTimeout)
        guard response.status == 200, let data = response.data else { return nil }
        return Self.parseTextResponse(data)
    }

    /// The streak line's own deadline; the intake budget (30s) would hold a
    /// notification hostage.
    static let streakTimeout: TimeInterval = 6

    static func streakRequestBody(model: String, kept: Bool, count: Int, language: String) -> Data? {
        let spoken = outputLanguageName(language: language)
        let system = """
        \(persona(language: language)) Your grandchild \(kept ? "has a streak of \(count) days going" : "just lost a \(count)-day streak"). \
        Write ONE short sentence in \(spoken), in her voice, like a real grandmother texting - same vibe as these (never copy one of them):
        \(streakExamples(language: language))
        Proud, funny, a bit teasing; a little English slang is fine, but no emoticons, no emoji. Do not sound like an AI: no balanced two-part sentences, no explaining, no lists, no quotation marks, do not always repeat the number. Under 20 words. \(addressStyle(language: language)).
        """
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.9,
            "max_tokens": 80,
            "reasoning": ["enabled": false],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "\(kept ? "kept" : "lost") \(count); angle: \(streakAngles.randomElement() ?? "proud")"],
            ],
        ]
        return JSON.data(from: body)
    }

    /// A per-line angle, so two streaks in a row do not read like the same
    /// card with the number swapped.
    static let streakAngles = [
        "bragging to the neighbours", "teasing", "a small threat about tomorrow",
        "a food reward at the finish line", "drill sergeant", "quiet pride",
    ]

    /// The register is shown, not described: describing it produced
    /// greeting-card lines in every language.
    static func streakExamples(language: String) -> String {
        switch GrannyLanguage(code: language) ?? .en {
        case .vi:
            return """
            - Bà tự hào khi có 1 chiến binh kỉ luật thép như cháu, 3 ngày rồi, keep it up
            - Ba ngày sạch sẽ, bà nể cháu thật đấy. Đừng có xịt ngày thứ tư nha
            - Cháu bà luyện kiểu này thì hàng xóm phải học tập, làm tiếp đi con
            """
        case .en:
            return """
            - Three days, dear. Your granny has a drill sergeant for a grandchild, apparently.
            - Look at you - three clean days. The neighbours' kids are getting shown up.
            - Not bad, dear. Do it again tomorrow and I'll stop calling you lazy.
            """
        case .fi:
            return """
            - Kolme päivää, kulta. Mummo alkaa kohta ylpeillä sinusta naapureille.
            - Kunnon kurinalaisuutta, jatka samaan malliin - huomenna ei sitten lipsuta.
            - Katso nyt, kolme puhdasta päivää. Naapurit jo kadehtivat.
            """
        }
    }

    static func parseTextResponse(_ data: Data) -> String? {
        guard let root = JSON.dict(from: data),
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Structured outputs are a request, not a guarantee: a provider that
    /// cannot honour `response_format` answers 400 ("model features
    /// structured outputs not support"). Only that 400 earns a retry with
    /// the plain body, whose prompt spells the JSON shape out - a bad model
    /// or a malformed request fails open without the extra round trip.
    private func post(_ body: Data, plainFallback: Data, timeout: TimeInterval) async -> Data? {
        let first = await perform(body, timeout: timeout)
        if first.status == 200 { return first.data }
        guard first.status == Self.unsupportedStructuredOutputStatus,
              let errorBody = first.data,
              Self.mentionsStructuredOutputs(errorBody)
        else { return nil }
        return await perform(plainFallback, timeout: timeout).data
    }

    /// HTTP 400 is what OpenRouter fronts for a provider that rejects the
    /// request shape (the structured-outputs case); 401/403/429/5xx are
    /// worth no retry.
    private static let unsupportedStructuredOutputStatus = 400

    /// OpenRouter nests the provider's own error in `metadata.raw`, so the
    /// whole body is searched for the structured-outputs complaint.
    static func mentionsStructuredOutputs(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return structuredOutputMarkers.contains { text.contains($0) }
    }

    static let structuredOutputMarkers = [
        "structured outputs", "structured_outputs", "response_format", "json_schema",
    ]

    private func perform(_ body: Data, timeout: TimeInterval) async -> (data: Data?, status: Int?) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (nil, nil) }
            return (data, http.statusCode)
        } catch {
            return (nil, nil)
        }
    }

    // MARK: - Request bodies

    static func decisionRequestBody(
        model: String, context: PageContext, tasks: [TaskItem], phase: Phase,
        language: String = "en", structured: Bool = true
    ) -> Data? {
        let taskList = tasks.map { task -> [String: Any] in
            [
                "title": task.title,
                "purpose": task.purpose ?? "",
                "done": task.done,
                "surfaces": task.allowedSurfaces,
            ]
        }
        let page: [String: Any] = [
            "url": context.url,
            "title": context.title ?? "",
            "channel": context.channel ?? "",
            "description": context.description ?? "",
            "kind": context.kind ?? "",
        ]
        let user: [String: Any] = [
            "page": page,
            "mode": phase.rawValue,
            "tasks": taskList,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["allow", "warn", "block"]],
                "message": ["type": "string"],
                "reason": ["type": "string"],
            ],
            "required": ["action", "message", "reason"],
            "additionalProperties": false,
        ]
        return chatBody(
            model: model,
            system: Self.decisionSystemPrompt(language: language),
            user: user,
            schemaName: "granny_decision",
            schema: schema,
            structured: structured,
            jsonHint: #"Answer with a single JSON object, no prose and no code fences: {"action": "allow" | "warn" | "block", "message": "<one short sentence>", "reason": "<one short English phrase>"}."#)
    }

    static func intakeRequestBody(
        model: String, text: String, language: String = "en", structured: Bool = true
    ) -> Data? {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "tasks": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "purpose": ["type": "string"],
                            "surfaces": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["title", "purpose", "surfaces"],
                        "additionalProperties": false,
                    ],
                ],
                "question": ["type": "string"],
            ],
            "required": ["tasks", "question"],
            "additionalProperties": false,
        ]
        return chatBody(
            model: model,
            system: Self.intakeSystemPrompt(language: language),
            user: ["list": text],
            schemaName: "granny_intake",
            schema: schema,
            structured: structured,
            jsonHint: #"Answer with a single JSON object, no prose and no code fences: {"tasks": [{"title": "<task>", "purpose": "<short phrase>", "surfaces": ["<url pattern>"]}], "question": "<one short question or an empty string>"}."#)
    }

    private static func chatBody(
        model: String, system: String, user: [String: Any], schemaName: String,
        schema: [String: Any], structured: Bool = true, jsonHint: String
    ) -> Data? {
        guard let userData = JSON.data(from: user), let userText = String(data: userData, encoding: .utf8) else { return nil }
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            // The answer, not the chain of thought: a reasoning model burns
            // the clock thinking about a one-line verdict or task.
            "reasoning": ["enabled": false],
            "messages": [
                ["role": "system", "content": structured ? system : system + "\n" + jsonHint],
                ["role": "user", "content": userText],
            ],
        ]
        if structured {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": schemaName, "strict": true, "schema": schema],
            ]
        }
        return JSON.data(from: body)
    }

    // MARK: - Prompts
    //
    // One shared English prompt body per job; only the persona line, the
    // output language and the address style follow the setting. Adding a
    // language means one persona, not a whole translated prompt.

    static func persona(language: String) -> String {
        switch GrannyLanguage(code: language) ?? .en {
        case .vi: return "You are Granny (Ngoại), a strict but affectionate Vietnamese grandmother."
        case .fi: return "You are Granny (Mummo), a strict but warm Finnish grandmother."
        case .en: return "You are Granny, a strict but warm grandmother."
        }
    }

    /// The language granny's user-facing lines are written in.
    static func outputLanguageName(language: String) -> String {
        switch GrannyLanguage(code: language) ?? .en {
        case .vi: return "Vietnamese"
        case .fi: return "Finnish"
        case .en: return "English"
        }
    }

    static func addressStyle(language: String) -> String {
        switch GrannyLanguage(code: language) ?? .en {
        case .vi: return #"address the grandchild as "cháu" and refer to yourself as "ngoại""#
        case .fi: return #"address the grandchild as "kulta" and refer to yourself as "mummo""#
        case .en: return #"address the grandchild as "dear" and refer to yourself as "granny""#
        }
    }

    static func decisionSystemPrompt(language: String) -> String {
        let spoken = outputLanguageName(language: language)
        return """
        \(persona(language: language)) You moderate your grandchild's browsing during a \
        deep-work session. You are given the page context (url, title, channel, description, kind) \
        and today's open tasks with their purpose. Judge the CONTENT, not the domain. Answer with \
        one of:
        - allow: content that serves deep work or is compatible with it. Music, \
        ambient and focus audio count as music: kind=music, an official music \
        video/audio/lyric video, an artist or music channel, or frequency/Hz, \
        binaural, solfeggio, meditation, sleep, rain/noise, lofi or study \
        playlists - even when the title promises wealth, health or sleep \
        benefits; listening is not a distraction. Also lectures, tutorials, \
        documentation, job applications; \
        tools/dashboards for work (developer tools, tracing/observability, analytics); \
        AI assistants and research tools (Perplexity, ChatGPT); search engine result \
        pages; communication tools \
        (Slack, Discord, email).
        - warn: work-adjacent but drifting; long-form video the grandchild chooses \
        to watch - movies, series, vlogs - is always warn, never block: the \
        negotiation exists so it can argue its case. An ambiguous video you cannot \
        identify is warn too.
        - block: passive entertainment that is not negotiable: shorts, gaming, \
        football/streams, pranks, reaction videos, gossip, endless feeds.
        Never allow on a guess: if you cannot tell what the page is, or your reason \
        would say "likely", "maybe" or "unclear", answer warn. When unsure between \
        warn and block, remember: long-form video is warn; shorts, games, streams and \
        feeds are block. When mode is night, it is past bedtime: the message sends \
        the grandchild to bed (it is late, tomorrow is another day) instead of \
        debating the work - the verdict stays what the content deserves. \
        message: exactly one short \(spoken) \
        sentence in granny's voice, warm and familiar like a grandmother talking to her \
        grandchild - \(addressStyle(language: language)). Never quote the task list or \
        repeat technical project jargon; talk about "your work" in plain, everyday words. \
        reason: one short English phrase.
        """
    }

    static func intakeSystemPrompt(language: String) -> String {
        let spoken = outputLanguageName(language: language)
        return """
        \(persona(language: language)) Convert your grandchild's raw task list into concrete \
        tasks. For each task set title (\(spoken), keep the grandchild's words), purpose (one \
        short \(spoken) phrase), and surfaces (URL patterns like "linkedin.com/jobs*" that the \
        task genuinely needs; use the site's domain as it exists today - sites move, for example \
        Threads is threads.com, not threads.net - and when the grandchild wrote a domain, use it \
        exactly). Never invent a domain: if the task does not name a site and you are not certain \
        of the real one, leave surfaces empty and ask a question instead. If any task is too \
        vague to verify later (e.g. "learn AI" with no concrete deliverable), set question to \
        exactly one short \(spoken) question asking for specifics, otherwise an empty string.
        """
    }

    // MARK: - Responses

    static func parseDecisionResponse(_ data: Data, source: String = "model") -> Decision? {
        guard let content = contentJSON(from: data),
              let action = content["action"] as? String,
              let actionValue = DecisionAction(rawValue: action),
              let reason = content["reason"] as? String
        else { return nil }
        let message = content["message"] as? String
        return Decision(actionValue, message: (message?.isEmpty ?? true) ? nil : message, reason: reason, source: source)
    }

    static func parseIntakeResponse(_ data: Data) -> ParsedIntake? {
        guard let content = contentJSON(from: data),
              let rawTasks = content["tasks"] as? [[String: Any]]
        else { return nil }
        let tasks = rawTasks.compactMap { raw -> TaskItem? in
            guard let title = raw["title"] as? String, !title.isEmpty else { return nil }
            return TaskItem(
                title: title,
                purpose: (raw["purpose"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                allowedSurfaces: (raw["surfaces"] as? [String] ?? [])
                    .compactMap(TaskParser.normalizeSurface))
        }
        guard !tasks.isEmpty else { return nil }
        let question = content["question"] as? String
        return ParsedIntake(tasks: tasks, question: (question?.isEmpty ?? true) ? nil : question)
    }

    private static func contentJSON(from data: Data) -> [String: Any]? {
        guard let root = JSON.dict(from: data),
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8)
        else { return nil }
        return JSON.dict(from: contentData)
    }
}
