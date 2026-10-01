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
    let session: URLSession
    /// Verdict label: "laya" or "jev" (same System One wire).
    let source: String

    public init(
        baseURL: String,
        apiKey: String,
        language: String = "en",
        timeout: TimeInterval = 8,
        source: String = "laya",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        self.language = language
        self.timeout = timeout
        self.source = source
        self.session = session
    }

    public func decide(url: String, title: String?, tasks: [TaskItem], phase: Phase) async -> Decision? {
        await decide(context: PageContext(url: url, title: title), tasks: tasks, phase: phase)
    }

    public func decide(context: PageContext, tasks: [TaskItem], phase: Phase) async -> Decision? {
        guard let body = Self.decisionRequestBody(language: language, context: context, tasks: tasks, phase: phase)
        else { return nil }
        // The base URL comes from the user's config: a malformed one must
        // fall through to the next tier, not crash the agent.
        guard let endpoint = URL(string: baseURL + "/systemone") else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return Self.parseResponse(data, source: source)
        } catch {
            return nil
        }
    }

    static func decisionRequestBody(
        language: String, context: PageContext, tasks: [TaskItem], phase: Phase
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
        // Non-English text can route to the English checkpoint; pin the
        // multilingual one for every non-English language.
        if !language.lowercased().hasPrefix("en") {
            body["model"] = "multilingual"
        }
        return JSON.data(from: body)
    }

    /// Gated on answer_confidence; below the gate the engine falls through
    /// to the next tier.
    public static let confidenceGate = 0.6

    static func parseResponse(_ data: Data, source: String = "laya") -> Decision? {
        guard let root = JSON.dict(from: data),
              let answers = root["answers"] as? [String: Any],
              let action = answers["action"] as? [String: Any],
              let choice = action["choice"] as? String,
              let actionValue = DecisionAction(rawValue: choice),
              let confidence = action["answer_confidence"] as? Double,
              confidence >= confidenceGate
        else { return nil }
        return Decision(actionValue, reason: "\(source) \(choice) @ \(confidence)", source: source)
    }
}
