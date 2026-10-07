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
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    public init(settings: LLMSettings, source: String = "model", session: URLSession = .shared) {
        self.settings = settings
        self.source = source
        self.session = session
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
    /// caller keeps its own template on any failure.
    public func streakLine(kept: Bool, count: Int, model: String) async -> String? {
        guard let body = Self.streakRequestBody(
            model: model, kept: kept, count: count, language: settings.language)
        else { return nil }
        let response = await perform(body, timeout: Self.intakeTimeout)
        guard response.status == 200, let data = response.data else { return nil }
        return Self.parseTextResponse(data)
    }

    static func streakRequestBody(model: String, kept: Bool, count: Int, language: String) -> Data? {
        let spoken = outputLanguageName(language: language)
        let system = """
        \(persona(language: language)) Your grandchild \(kept ? "kept a clean streak" : "lost a streak") \
        of \(count) days. Write ONE short sentence in \(spoken), in your own voice - warm, a little \
        strict, never cheesy - that \(kept ? "praises them" : "comforts them") and sends them back \
        to work. No emoji, no quotation marks, no lists; under 20 words. \(addressStyle(language: language)).
        """
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.9,
            "max_tokens": 80,
            "reasoning": ["enabled": false],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": kept ? "kept \(count)" : "lost \(count)"],
            ],
        ]
        return JSON.data(from: body)
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
        exactly). If any task is too vague to verify later (e.g. "learn AI" with no concrete \
        deliverable), set question to exactly one short \(spoken) question asking for specifics, \
        otherwise an empty string.
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
