import XCTest
@testable import GrannyCore

final class ConfigTests: XCTestCase {
    func testDefaultsAreSane() {
        let config = GrannyConfig()
        XCTAssertEqual(config.model, "deepseek/deepseek-v4.1-flash")
        XCTAssertEqual(config.wakeHour, 7)
        XCTAssertEqual(config.bedtimeHour, 23)
        XCTAssertTrue(config.blockedDomains.contains("facebook.com"))
        XCTAssertTrue(config.blockedDomains.contains("tiktok.com"))
        XCTAssertTrue(config.dohDomains.contains("dns.google"))
        XCTAssertTrue(config.contextHosts.contains("youtube.com"))
        XCTAssertEqual(config.appearance, "dark")
        XCTAssertEqual(config.language, "en")
        XCTAssertEqual(config.jevModel, "typesafe/jev-router")
        XCTAssertTrue(config.checkForUpdates)
        XCTAssertFalse(config.token.isEmpty)
    }

    func testTokenIsUniquePerConfig() {
        XCTAssertNotEqual(GrannyConfig().token, GrannyConfig().token)
    }

    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("granny-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var config = GrannyConfig()
        config.openRouterKey = "test-key"
        config.wakeHour = 8
        config.langfuse = LangfuseConfig(baseURL: "https://cloud.langfuse.com", publicKey: "pk", secretKey: "sk")
        config.jevURL = "https://jev.example/v1"
        config.jevKey = "jev-key"
        config.appearance = "light"
        try config.save(to: url)

        let loaded = GrannyConfig.load(from: url)
        XCTAssertEqual(loaded.openRouterKey, "test-key")
        XCTAssertEqual(loaded.wakeHour, 8)
        XCTAssertEqual(loaded.langfuse?.publicKey, "pk")
        XCTAssertEqual(loaded.jevURL, "https://jev.example/v1")
        XCTAssertEqual(loaded.jevKey, "jev-key")
        XCTAssertEqual(loaded.appearance, "light")
        XCTAssertEqual(loaded.token, config.token)
    }

    func testSaveSetsOwnerOnlyPermissions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("granny-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try GrannyConfig().save(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }

    func testPartialJSONFallsBackToDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("granny-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"model": "custom/model", "wakeHour": 6}"#.utf8).write(to: url)
        let loaded = GrannyConfig.load(from: url)
        XCTAssertEqual(loaded.model, "custom/model")
        XCTAssertEqual(loaded.wakeHour, 6)
        XCTAssertEqual(loaded.bedtimeHour, 23)
        XCTAssertTrue(loaded.blockedDomains.contains("facebook.com"))
    }

    func testMissingFileCreatesDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("granny-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let loaded = GrannyConfig.load(from: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(loaded.model, "deepseek/deepseek-v4.1-flash")
    }

    func testDefaultEntertainmentAppsAllHaveDisplayNames() {
        for bundleID in GrannyConfig.defaultEntertainmentApps {
            XCTAssertNotNil(
                GrannyConfig.defaultEntertainmentAppNames[bundleID],
                "no display name for default app \(bundleID)")
        }
    }

    func testCorruptConfigIsKeptAsideNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("granny-config-\(UUID().uuidString).json")
        let corrupt = Data("{ not json at all".utf8)
        try corrupt.write(to: url)
        let loaded = GrannyConfig.load(from: url)
        XCTAssertEqual(loaded.model, GrannyConfig().model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "corrupt file was overwritten")
        let backups = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corrupt)
        for backup in backups { try? FileManager.default.removeItem(at: backup) }
    }

    func testDecidePortNumberFallsBackOnOutOfRangeValues() {
        XCTAssertEqual(GrannyConfig(decidePort: 8080).decidePortNumber, 8080)
        XCTAssertEqual(GrannyConfig(decidePort: 70000).decidePortNumber, UInt16(GrannyConfig.defaultDecidePort))
        XCTAssertEqual(GrannyConfig(decidePort: -1).decidePortNumber, UInt16(GrannyConfig.defaultDecidePort))
        XCTAssertEqual(GrannyConfig(decidePort: 0).decidePortNumber, UInt16(GrannyConfig.defaultDecidePort))
    }
}
