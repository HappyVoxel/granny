import Foundation

/// Minimal Langfuse ingestion client: decisions and (later) chats land as
/// traces. No Swift SDK exists; the ingestion API is one HTTP POST, and a
/// framework would be more code than this.
public final class TraceClient: @unchecked Sendable {
    public struct Span: Sendable {
        public var name: String
        public var traceName: String
        public var input: [String: String]
        public var output: [String: String]
        public var model: String?
        public var startedAt: Date
        public var endedAt: Date

        public init(
            name: String,
            traceName: String,
            input: [String: String],
            output: [String: String],
            model: String? = nil,
            startedAt: Date,
            endedAt: Date
        ) {
            self.name = name
            self.traceName = traceName
            self.input = input
            self.output = output
            self.model = model
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    private let config: LangfuseConfig?
    private let session: URLSession
    private let pending = DispatchGroup()

    /// Pass nil config (or call with no keys) to disable tracing entirely.
    public init(config: LangfuseConfig?, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public var isEnabled: Bool { config != nil }

    /// Waits for in-flight ingestion posts; short-lived processes (the CLI)
    /// must call this before exiting or the traces die with the process.
    public func flush(timeout: TimeInterval = 3) {
        _ = pending.wait(timeout: .now() + timeout)
    }

    public func record(_ span: Span) {
        guard let config, let body = Self.otlpBody(span: span) else { return }
        // Langfuse v4: OTLP over HTTP with JSON encoding. The legacy
        // /api/public/ingestion endpoint is unavailable to organizations
        // created on or after 2026-09-16.
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // A malformed host from the config disables tracing, never the app.
        guard let endpoint = URL(string: base + "/api/public/otel/v1/traces") else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("4", forHTTPHeaderField: "x-langfuse-ingestion-version")
        let credentials = Data("\(config.publicKey):\(config.secretKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        let debug = ProcessInfo.processInfo.environment[GrannyEnv.traceDebug] == "1"
        pending.enter()
        session.dataTask(with: request) { data, response, error in
            defer { self.pending.leave() }
            guard debug else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            FileHandle.standardError.write(Data("trace: status \(status) \(body.prefix(300))\n".utf8))
            if let error {
                FileHandle.standardError.write(Data("trace: error \(error)\n".utf8))
            }
        }.resume()
    }

    /// Pure payload builder: one OTLP span carrying the Langfuse
    /// attributes: trace name, observation type/input/output, and
    /// the model name for generation spans.
    public static func otlpBody(span: Span) -> Data? {
        var attributes: [[String: Any]] = [
            ["key": "langfuse.trace.name", "value": ["stringValue": span.traceName]],
            ["key": "langfuse.observation.type", "value": ["stringValue": span.model == nil ? "span" : "generation"]],
            ["key": "langfuse.observation.input", "value": ["stringValue": jsonString(span.input)]],
            ["key": "langfuse.observation.output", "value": ["stringValue": jsonString(span.output)]],
        ]
        if let model = span.model {
            attributes.append(["key": "langfuse.observation.model.name", "value": ["stringValue": model]])
        }
        let otlpSpan: [String: Any] = [
            "traceId": randomHex(bytes: 16),
            "spanId": randomHex(bytes: 8),
            "name": span.name,
            "kind": 1,
            "startTimeUnixNano": nanoString(span.startedAt),
            "endTimeUnixNano": nanoString(span.endedAt),
            "attributes": attributes,
        ]
        let body: [String: Any] = [
            "resourceSpans": [
                [
                    "resource": [
                        "attributes": [
                            ["key": "service.name", "value": ["stringValue": "granny-agent"]],
                        ],
                    ],
                    "scopeSpans": [
                        [
                            "scope": ["name": "granny-agent", "version": "0.1.0"],
                            "spans": [otlpSpan],
                        ],
                    ],
                ],
            ],
        ]
        return JSON.data(from: body)
    }

    private static func jsonString(_ object: [String: String]) -> String {
        guard let data = JSON.data(from: object), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func nanoString(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1_000_000_000))
    }

    private static func randomHex(bytes count: Int) -> String {
        (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
