import XCTest
@testable import GrannyCore

final class ModelCatalogTests: XCTestCase {
    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.requestCount = 0
    }

    func testProviderConfigFallback() {
        XCTAssertEqual(ModelProvider(configValue: "openrouter"), .openRouter)
        XCTAssertEqual(ModelProvider(configValue: nil), .default)
        XCTAssertEqual(ModelProvider(configValue: "some-future-provider"), .default)
    }

    func testParseOpenRouterCatalog() {
        let payload = """
        {"data": [
          {"id": "vendor/beta", "name": "Vendor: Beta"},
          {"id": "vendor/alpha"},
          {"id": "", "name": "no id"},
          {"name": "also no id"}
        ]}
        """
        let models = ModelCatalog.parseOpenRouter(Data(payload.utf8))
        XCTAssertEqual(models.map(\.id), ["vendor/beta", "vendor/alpha"], "provider order is kept")
        XCTAssertEqual(models[1].name, "vendor/alpha", "a missing name falls back to the id")
    }

    func testFilterMatchesIdAndNameCaseInsensitively() {
        let models = [
            ModelInfo(id: "vendor/model:free", name: "Vendor: Model (free)"),
            ModelInfo(id: "vendor/model-pro", name: "Vendor: Model Pro"),
        ]
        XCTAssertEqual(ModelCatalog.filter(models, query: "FREE").map(\.id), ["vendor/model:free"])
        XCTAssertEqual(ModelCatalog.filter(models, query: "pro").map(\.id), ["vendor/model-pro"])
        XCTAssertEqual(ModelCatalog.filter(models, query: "  ").count, 2, "blank query passes all")
        XCTAssertEqual(ModelCatalog.filter(models, query: "nothing").count, 0)
    }

    func testFetchOpenRouterUsesTheModelsEndpoint() async {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url, ModelCatalog.openRouterURL)
            let data = Data(#"{"data": [{"id": "a/b", "name": "A: B"}]}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let models = await ModelCatalog.fetch(.openRouter, session: mockSession())
        XCTAssertEqual(models.map(\.id), ["a/b"])
    }

    func testFetchFailureAnswersEmpty() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let models = await ModelCatalog.fetch(.openRouter, session: mockSession())
        XCTAssertTrue(models.isEmpty, "a failed fetch must not look like a catalogue")

        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = await ModelCatalog.fetch(.openRouter, session: mockSession())
        XCTAssertTrue(offline.isEmpty)
    }
}
