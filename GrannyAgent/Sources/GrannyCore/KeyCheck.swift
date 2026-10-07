import Foundation

/// What a credential check found. Transport failures are `unreachable`,
/// never `invalid`: being offline must not paint a working key red.
public enum KeyCheckResult: Sendable, Equatable {
    case valid
    case invalid
    case unreachable
}

/// Lightweight credential checks for Settings: one small request per
/// provider, so a pasted key can show a check or a cross before Save. New
/// providers add one function here; the field component stays the same.
public enum KeyCheck {
    /// OpenRouter: GET /api/v1/key, the cheapest authenticated call.
    public static func openRouter(key: String, session: URLSession = .shared) async -> KeyCheckResult {
        guard !key.isEmpty, let url = httpURL("https://openrouter.ai/api/v1/key") else { return .invalid }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await perform(request, session: session)
    }

    /// System One (Laya, Jev): the smallest real decision request against
    /// the configured endpoint (base or full `.../systemone`); auth failures
    /// answer 401/403. An empty key is fine for keyless hosts. A bare base
    /// is probed exactly the way the client probes it, so the check and the
    /// decision path agree on where the endpoint is.
    public static func systemOne(baseURL: String, key: String, session: URLSession = .shared) async -> KeyCheckResult {
        guard let body = LayaClient.decisionRequestBody(
            language: "en",
            context: PageContext(url: "https://example.com", title: "granny key check"),
            tasks: [],
            phase: .working)
        else { return .invalid }
        let candidates = LayaClient.endpointCandidates(from: baseURL)
        guard !candidates.isEmpty else { return .invalid }
        for endpoint in candidates {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 10
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let status = await status(of: request, session: session) else { return .unreachable }
            if status == 404 { continue }
            if (200..<300).contains(status) { return .valid }
            if status == 401 || status == 403 { return .invalid }
            return .unreachable
        }
        return .unreachable
    }

    /// The HTTP status, or nil when the request never got an answer.
    private static func status(of request: URLRequest, session: URLSession) async -> Int? {
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    private static func perform(_ request: URLRequest, session: URLSession) async -> KeyCheckResult {
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            if (200..<300).contains(http.statusCode) { return .valid }
            if http.statusCode == 401 || http.statusCode == 403 { return .invalid }
            return .unreachable
        } catch {
            return .unreachable
        }
    }

    /// Absolute http(s) only: a relative string must not reach URLSession.
    private static func httpURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}
