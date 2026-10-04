import CryptoKit
import XCTest
@testable import GrannyCore

final class UpdateInstallerTests: XCTestCase {
    final class FakeRunner: CommandRunning, @unchecked Sendable {
        var calls: [(executable: String, arguments: [String])] = []
        var launches: [(executable: String, arguments: [String])] = []
        var results: [String: CommandResult] = [:]
        var handler: ((String, [String]) throws -> CommandResult)?

        func run(_ executable: String, arguments: [String], environment: [String: String]?) throws -> CommandResult {
            calls.append((executable, arguments))
            if let handler { return try handler(executable, arguments) }
            return results[executable] ?? CommandResult(status: 0, output: "")
        }

        func launch(_ executable: String, arguments: [String], environment: [String: String]?) throws {
            launches.append((executable, arguments))
        }
    }

    private let fileManager = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("granny-update-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MockURLProtocol.handler = nil
        try? fileManager.removeItem(at: root)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func mockSession(zip: Data, sha: Data) -> URLSession {
        MockURLProtocol.handler = { request in
            let name = request.url?.lastPathComponent ?? ""
            let data = name.hasSuffix(".sha256") ? sha : zip
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeBundle(at directory: URL) throws -> URL {
        let app = directory.appendingPathComponent("granny.app")
        try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
        return app
    }

    /// A fake Homebrew layout: prefix/bin/brew plus the cask's Caskroom app.
    private func makeBrewPrefix() throws -> (brew: String, prefix: URL, caskApp: URL) {
        let prefix = root.appendingPathComponent("brew")
        let bin = prefix.appendingPathComponent("bin")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let brew = bin.appendingPathComponent("brew")
        fileManager.createFile(atPath: brew.path, contents: Data("#!/bin/sh\n".utf8))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        let caskApp = try makeBundle(at: prefix.appendingPathComponent("Caskroom/granny/0.1.4"))
        return (brew.path, prefix, caskApp)
    }

    private func waitForInstall(
        _ installer: UpdateInstaller,
        version: String,
        bundle: URL
    ) -> Result<UpdateInstaller.Outcome, Error> {
        let done = expectation(description: "install")
        var outcome: Result<UpdateInstaller.Outcome, Error>?
        installer.install(version: version, currentBundle: bundle) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return outcome ?? .failure(UpdateInstaller.UpdateError.tool("no completion"))
    }

    private func assertFailure(
        _ outcome: Result<UpdateInstaller.Outcome, Error>,
        _ expected: UpdateInstaller.UpdateError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = outcome else {
            return XCTFail("expected failure, got \(outcome)", file: file, line: line)
        }
        XCTAssertEqual(error as? UpdateInstaller.UpdateError, expected, file: file, line: line)
    }

    // MARK: - Brew path

    func testBrewPathWhenRunningBundleIsTheCaskCopy() throws {
        let (brew, prefix, caskApp) = try makeBrewPrefix()
        let runner = FakeRunner()
        let installer = UpdateInstaller(
            runner: runner,
            workRoot: root.appendingPathComponent("work"),
            brewPrefixes: [prefix.path],
            appDirectory: root.appendingPathComponent("Applications"))

        let outcome = waitForInstall(installer, version: "0.1.4", bundle: caskApp)
        XCTAssertEqual(try outcome.get(), .upgradedByBrew)
        XCTAssertEqual(runner.calls.map(\.executable), [brew, brew])
        XCTAssertEqual(runner.calls.map(\.arguments), [["update"], ["upgrade", "--cask", "granny"]])
    }

    func testBrewPathWhenRunningBundleIsTheAppDirectoryCopy() throws {
        let (_, prefix, _) = try makeBrewPrefix()
        let appDirectory = root.appendingPathComponent("Applications")
        let app = try makeBundle(at: appDirectory)
        let runner = FakeRunner()
        let installer = UpdateInstaller(
            runner: runner,
            workRoot: root.appendingPathComponent("work"),
            brewPrefixes: [prefix.path],
            appDirectory: appDirectory)

        let outcome = waitForInstall(installer, version: "0.1.4", bundle: app)
        XCTAssertEqual(try outcome.get(), .upgradedByBrew)
    }

    func testBrewFailureCarriesTheOutputTail() throws {
        let (brew, prefix, caskApp) = try makeBrewPrefix()
        let runner = FakeRunner()
        runner.results[brew] = CommandResult(status: 1, output: "Error: boom\nsecond\nthird\nfourth")
        let installer = UpdateInstaller(
            runner: runner,
            workRoot: root.appendingPathComponent("work"),
            brewPrefixes: [prefix.path],
            appDirectory: root.appendingPathComponent("Applications"))

        let outcome = waitForInstall(installer, version: "0.1.4", bundle: caskApp)
        assertFailure(outcome, .brewFailed("second / third / fourth"))
    }

    // MARK: - Zip path

    /// A dev copy while brew owns a *different* bundle must not upgrade the
    /// cask behind the user's back; it takes the zip path.
    func testZipPathWhenBrewOwnsADifferentCopy() throws {
        let (_, prefix, _) = try makeBrewPrefix()
        let devApp = try makeBundle(at: root.appendingPathComponent("dev"))

        let zip = Data("zip-bytes".utf8)
        let sha = Data("\(sha256Hex(zip))  granny-0.1.4.zip\n".utf8)
        let runner = FakeRunner()
        runner.handler = { [fileManager] executable, arguments in
            if executable == "/usr/bin/ditto" {
                let destination = URL(fileURLWithPath: arguments.last!)
                try fileManager.createDirectory(
                    at: destination.appendingPathComponent("granny.app"),
                    withIntermediateDirectories: true)
            }
            return CommandResult(status: 0, output: "")
        }
        let installer = UpdateInstaller(
            session: mockSession(zip: zip, sha: sha),
            runner: runner,
            workRoot: root.appendingPathComponent("work"),
            brewPrefixes: [prefix.path],
            appDirectory: root.appendingPathComponent("Applications"))

        let outcome = waitForInstall(installer, version: "0.1.4", bundle: devApp)
        XCTAssertEqual(try outcome.get(), .willSwap)
        XCTAssertFalse(runner.calls.contains { $0.executable.contains("/brew") }, "brew must not run")
        XCTAssertTrue(runner.calls.contains { $0.executable == "/usr/bin/ditto" })
        XCTAssertTrue(runner.launches.contains { $0.executable == "/bin/sh" }, "helper is launched detached")
    }

    func testChecksumMismatchFailsAndCleansTheWorkDirectory() throws {
        let devApp = try makeBundle(at: root.appendingPathComponent("dev"))
        let zip = Data("zip-bytes".utf8)
        let sha = Data("deadbeef  granny-0.1.4.zip\n".utf8)
        let work = root.appendingPathComponent("work")
        let installer = UpdateInstaller(
            session: mockSession(zip: zip, sha: sha),
            runner: FakeRunner(),
            workRoot: work,
            brewPrefixes: [],
            appDirectory: root.appendingPathComponent("Applications"))

        let outcome = waitForInstall(installer, version: "0.1.4", bundle: devApp)
        assertFailure(outcome, .checksum)
        let leftovers = try fileManager.contentsOfDirectory(atPath: work.path)
        XCTAssertTrue(leftovers.isEmpty, "failed update left \(leftovers) behind")
    }

    func testHTTPErrorFailsAndCleansTheWorkDirectory() throws {
        let devApp = try makeBundle(at: root.appendingPathComponent("dev"))
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let work = root.appendingPathComponent("work")
        let installer = UpdateInstaller(
            session: URLSession(configuration: config),
            runner: FakeRunner(),
            workRoot: work,
            brewPrefixes: [],
            appDirectory: root.appendingPathComponent("Applications"))

        let outcome = waitForInstall(installer, version: "0.1.4", bundle: devApp)
        assertFailure(outcome, .download(404))
        let leftovers = try fileManager.contentsOfDirectory(atPath: work.path)
        XCTAssertTrue(leftovers.isEmpty, "failed update left \(leftovers) behind")
    }
}
