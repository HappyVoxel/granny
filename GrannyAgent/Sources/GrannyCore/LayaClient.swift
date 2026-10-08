import Foundation

/// The fast-classifier tier (self-hosted Laya, or Jev when Laya is absent):
/// Jev-compatible System One wire format. Keeps browsing URLs on local
/// infrastructure and answers with a calibrated probability the engine gates
/// on. An actor because it remembers which endpoint answered: a bare base
/// URL is probed once, then reused.
public actor LayaClient {
    let baseURL: String
    let apiKey: String
    let timeout: TimeInterval
    let language: String
    let model: String?
    let minConfidence: Double
    let session: URLSession
    let source: String
    private var resolvedEndpoint: URL?

    public init(
        baseURL: String,
        apiKey: String,
        language: String = "en",
        model: String? = nil,
        minConfidence: Double = LayaClient.confidenceGate,
        timeout: TimeInterval = 8,
        source: String = "laya",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        self.apiKey = apiKey
        self.language = language
        self.model = model
        self.minConfidence = minConfidence
        self.timeout = timeout
        self.source = source
        self.session = session
    }

    /// The hosted console the Settings shortcut points to: a product
    /// shortcut for someone who has no Laya yet, not a derivation of the
    /// user's own URL.
    public static let hostedConsoleURL = URL(string: "https://console.opscom.io")!

    /// Whether that shortcut is useful for this configuration. Someone who
    /// already points granny at their own deployment elsewhere does not
    /// need a "get a key" button, so the card hides it.
    public static func hostedConsoleApplies(to configured: String) -> Bool {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return URL(string: trimmed)?.host?.lowercased() == hostedConsoleURL.host
    }

    /// The console hands out full endpoints (`https://host/v1/systemone`),
    /// while `https://host/v1` style bases expect granny to append the path.
    /// Both are used as the user typed them, minus the appended suffix when
    /// the endpoint is already there.
    public static func endpointURL(from configured: String) -> URL? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil
        else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix("systemone") {
            components.path = "/" + path + (path.isEmpty ? "" : "/") + "systemone"
        }
        return components.url
    }

    /// What to try, in order. An explicit endpoint is trusted as typed; a
    /// bare base gets the console shapes as fallbacks (`/v1/systemone`,
    /// `/api/v1/systemone`) - probed only after the first candidate answers
    /// 404, so a correct paste never pays for the search. A base with a path
    /// (`…/v1`) is already explicit: its candidates are exactly what it says.
    static func endpointCandidates(from configured: String) -> [URL] {
        guard let primary = endpointURL(from: configured) else { return [] }
        if configured.lowercased().contains("systemone") { return [primary] }
        guard var components = URLComponents(url: primary, resolvingAgainstBaseURL: false),
              components.path == "/systemone"
        else { return [primary] }
        var candidates = [primary]
        for path in ["/v1/systemone", "/api/v1/systemone"] {
            components.path = path
            if let url = components.url { candidates.append(url) }
        }
        return candidates
    }

    public func decide(url: String, title: String?, tasks: [TaskItem], phase: Phase) async -> Decision? {
        await decide(context: PageContext(url: url, title: title), tasks: tasks, phase: phase)
    }

    public func decide(context: PageContext, tasks: [TaskItem], phase: Phase) async -> Decision? {
        await decideDetailed(context: context, tasks: tasks, phase: phase).decision
    }

    /// Same verdict, plus why it was unusable when nil ("http 403",
    /// "transport: …", "low confidence 0.32"). The engine traces the miss so
    /// a silent classifier never hides inside the fallback chain.
    public func decideDetailed(
        context: PageContext, tasks: [TaskItem], phase: Phase
    ) async -> (decision: Decision?, miss: String?) {
        guard let body = Self.decisionRequestBody(
            language: language, context: context, tasks: tasks, phase: phase, model: model)
        else { return (nil, "bad request body") }
        // A remembered endpoint skips the search entirely.
        if let resolvedEndpoint {
            return await send(body, to: resolvedEndpoint)
        }
        var last: (decision: Decision?, miss: String?) = (nil, "bad endpoint")
        for endpoint in Self.endpointCandidates(from: baseURL) {
            last = await send(body, to: endpoint)
            // A transport failure means the host is down: another path on it
            // would fail the same way.
            if last.miss?.hasPrefix("transport:") == true { return last }
            if last.miss != Self.notFoundMiss {
                resolvedEndpoint = endpoint
                return last
            }
        }
        return last
    }

    /// The 404 that says "this path does not exist", the only miss worth
    /// trying another candidate for.
    static let notFoundMiss = "http 404"

    private func send(_ body: Data, to endpoint: URL) async -> (decision: Decision?, miss: String?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        // Keyless hosts (the free Zaitlabs deployment) take no Authorization.
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (nil, "not http") }
            guard http.statusCode == 200 else { return (nil, "http \(http.statusCode)") }
            return Self.parseResponseDetailed(data, source: source, gate: minConfidence)
        } catch {
            return (nil, "transport: \(error.localizedDescription)")
        }
    }

    static func decisionRequestBody(
        language: String, context: PageContext, tasks: [TaskItem], phase: Phase, model: String? = nil
    ) -> Data? {
        let state: [String: Any] = [
            "url": context.url,
            "title": context.title ?? "",
            "channel": context.channel ?? "",
            "kind": context.kind ?? "",
            "mode": phase.rawValue,
            "tasks": tasks.filter { !$0.done }.map { $0.title },
        ]
        var body: [String: Any] = [
            "state": state,
            "questions": [
                "action": [
                    "type": "choice",
                    "instructions": "Judge the page content (title, channel, kind), not the domain. "
                        + "Would opening it serve the grandchild's deep work right now, given the open tasks?",
                    "criteria": [
                        "allow": "content that clearly serves the open tasks: music only "
                            + "when the page is unmistakably music (kind=music, official "
                            + "MV/audio, artist channel); lectures, tutorials, documentation; "
                            + "tools and dashboards the grandchild uses for work (developer "
                            + "tools, tracing/observability, analytics); AI assistants and "
                            + "research tools (Perplexity, ChatGPT); communication tools "
                            + "(Slack, Discord, email)",
                        "warn": "work-adjacent but negotiable: social feeds, movies, "
                            + "series, vlogs, general-interest videos - long-form "
                            + "entertainment the grandchild may argue serves a task, and "
                            + "ambiguous videos that cannot be identified; always warn, "
                            + "never block",
                        "block": "non-negotiable passive entertainment: shorts, gaming, "
                            + "football streams, pranks, reaction videos, gossip",
                    ],
                ],
            ],
        ]
        // A configured model wins; otherwise non-English text pins the
        // multilingual checkpoint (the English default would mangle it).
        if let model, !model.isEmpty {
            body["model"] = model
        } else if !language.lowercased().hasPrefix("en") {
            body["model"] = "multilingual"
        }
        return JSON.data(from: body)
    }

    /// Gated on the chosen answer's confidence; below the gate the engine
    /// falls through to the next tier. Hosts differ on the field name: the
    /// OpsCom console answers `answer_confidence`, the free Zaitlabs
    /// deployment answers `confidence`.
    public static let confidenceGate = 0.6

    static func parseResponse(
        _ data: Data, source: String = "laya", gate: Double = LayaClient.confidenceGate
    ) -> Decision? {
        parseResponseDetailed(data, source: source, gate: gate).decision
    }

    static func parseResponseDetailed(
        _ data: Data, source: String = "laya", gate: Double = LayaClient.confidenceGate
    ) -> (decision: Decision?, miss: String?) {
        guard let root = JSON.dict(from: data),
              let answers = root["answers"] as? [String: Any],
              let action = answers["action"] as? [String: Any],
              let choice = action["choice"] as? String,
              let actionValue = DecisionAction(rawValue: choice),
              let confidence = (action["answer_confidence"] as? Double) ?? (action["confidence"] as? Double)
        else { return (nil, "unparseable response") }
        guard confidence >= gate else {
            return (nil, String(format: "low confidence %.2f", confidence))
        }
        return (Decision(actionValue, reason: "\(source) \(choice) @ \(confidence)", source: source), nil)
    }
}
