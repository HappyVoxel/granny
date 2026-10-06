import Foundation

/// One model as its provider lists it.
public struct ModelInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Which LLM provider serves the model tier. OpenRouter is the only one so
/// far; the config stores the raw value, so a later provider is a new case
/// here plus a fetch, not a config migration.
public enum ModelProvider: String, CaseIterable, Sendable {
    case openRouter = "openrouter"

    public static let `default`: ModelProvider = .openRouter

    public var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        }
    }

    /// Unknown or missing config values fall back to the default, so a
    /// config written by a newer build never breaks an older one.
    public init(configValue: String?) {
        self = configValue.flatMap(ModelProvider.init(rawValue:)) ?? .default
    }
}

/// The provider's model list, fetched at Settings time rather than
/// hardcoded: new models appear the day they ship, and nothing in granny
/// names a specific model.
public enum ModelCatalog {
    static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/models")!
    static let requestTimeout: TimeInterval = 15

    /// The whole catalogue for a provider; empty on any failure, which the
    /// Settings field treats as "type the id directly".
    public static func fetch(_ provider: ModelProvider, session: URLSession = .shared) async -> [ModelInfo] {
        switch provider {
        case .openRouter:
            await fetchOpenRouter(session: session)
        }
    }

    static func fetchOpenRouter(session: URLSession) async -> [ModelInfo] {
        var request = URLRequest(url: openRouterURL)
        request.timeoutInterval = requestTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return [] }
            return parseOpenRouter(data)
        } catch {
            return []
        }
    }

    /// `{"data": [{"id": "vendor/model", "name": "Vendor: Model"}, ...]}`.
    /// The provider's own ordering is kept (it is curated server-side).
    static func parseOpenRouter(_ data: Data) -> [ModelInfo] {
        guard let root = JSON.dict(from: data),
              let rows = root["data"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return ModelInfo(id: id, name: name)
        }
    }

    /// Case-insensitive substring over id and name; an empty query passes
    /// everything through.
    public static func filter(_ models: [ModelInfo], query: String) -> [ModelInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return models }
        return models.filter {
            $0.id.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
        }
    }
}
