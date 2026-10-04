import Foundation

/// The fast-classifier tier (self-hosted Laya, or Jev when Laya is absent):
/// Jev-compatible System One wire format. Keeps browsing URLs on local
/// infrastructure and answers with a calibrated probability the engine gates
/// on.
public struct LayaClient: Sendable {
    let baseURL: String
    let apiKey: String
    let timeout: TimeInterval
    let language: String
    /// Pins a checkpoint on hosts that take one (e.g. `laya/multilingual`);
    /// nil keeps the language-based default.
    let model: String?
    /// Confidence gate for the answer; hosts calibrate differently.
    let minConfidence: Double
    let session: URLSession
    /// Verdict label: "laya" or "jev" (same System One wire).
    let source: String

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

    public func decide(url: String, title: String?, tasks: [TaskItem], phase: Phase) async -> Decision? {
        await decide(context: PageContext(url: url, title: title), tasks: tasks, phase: phase)
    }

    public func decide(context: PageContext, tasks: [TaskItem], phase: Phase) async -> Decision? {
        guard let body = Self.decisionRequestBody(
            language: language, context: context, tasks: tasks, phase: phase, model: model)
        else { return nil }
        // The URL comes from the user's config: a malformed one must fall
        // through to the next tier, not crash the agent.
        guard let endpoint = Self.endpointURL(from: baseURL) else { return nil }
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
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return Self.parseResponse(data, source: source, gate: minConfidence)
        } catch {
            return nil
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
                        "allow": "music in any form - songs, playlists, radio, lo-fi, ambient, "
                            + "instrumental, music videos; lectures, tutorials, documentation; "
                            + "tools and dashboards the grandchild uses for work (developer "
                            + "tools, tracing/observability, analytics); AI assistants and "
                            + "research tools (Perplexity, ChatGPT); communication tools "
                            + "(Slack, Discord, email); anything that directly serves the "
                            + "open tasks",
                        "warn": "work-adjacent but likely to drift: social feeds, general-interest "
                            + "videos that could serve a task but smell like a break",
                        "block": "passive video entertainment: movies, series, vlogs, gaming, "
                            + "football streams, pranks, reaction videos, gossip, shorts",
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
        guard let root = JSON.dict(from: data),
              let answers = root["answers"] as? [String: Any],
              let action = answers["action"] as? [String: Any],
              let choice = action["choice"] as? String,
              let actionValue = DecisionAction(rawValue: choice),
              let confidence = (action["answer_confidence"] as? Double) ?? (action["confidence"] as? Double),
              confidence >= gate
        else { return nil }
        return Decision(actionValue, reason: "\(source) \(choice) @ \(confidence)", source: source)
    }
}
