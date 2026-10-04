import Foundation

/// Installs the release the update checker found. A Homebrew install goes
/// through `brew update` + `brew upgrade --cask granny`, so brew's
/// bookkeeping stays honest; anything else downloads the release zip, checks
/// its published sha256, and hands the swap to a small shell helper. The
/// helper waits for granny to quit, replaces the bundle and reopens it, so
/// nothing has to survive the quit inside this process.
///
/// Every system interaction has a seam: the network session, the command
/// runner, and the tool paths (`GRANNY_BREW`, `GRANNY_DITTO`,
/// `GRANNY_SWAP_SHELL`) are injectable, so the tests cover both paths and
/// the e2e suites can fake the tools.
public final class UpdateInstaller {
    public enum Outcome: Equatable, Sendable {
        /// Brew did the swap; the app reopens itself the usual way.
        case upgradedByBrew
        /// The helper is queued; the app should just terminate.
        case willSwap
    }

    public enum UpdateError: Error, Equatable, Sendable {
        case download(Int)
        case checksum
        case unpack
        case notWritable
        case brewFailed(String)
        case tool(String)

        /// Technical fallback; the UI speaks through `GrannyLines.updateFailure`.
        public var errorDescription: String? {
            switch self {
            case .download(let status): return "download failed (HTTP \(status))"
            case .checksum: return "archive checksum mismatch"
            case .unpack: return "archive did not contain granny.app"
            case .notWritable: return "bundle directory is not writable"
            case .brewFailed(let output): return "brew failed: \(output)"
            case .tool(let message): return "tool failed: \(message)"
            }
        }
    }

    /// Runs after granny exits: old bundle aside, new bundle in, old bundle
    /// gone, app reopened - and the old bundle comes back if the swap fails.
    static let swapScript = """
    #!/bin/sh
    set -e
    pid="$1"
    src="$2"
    dst="$3"
    work="$4"
    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.3
    done
    rm -rf "$dst.granny-old"
    mv "$dst" "$dst.granny-old"
    if ! mv "$src" "$dst"; then
      mv "$dst.granny-old" "$dst"
      exit 1
    fi
    rm -rf "$dst.granny-old"
    open --env GRANNY_SHOW_WINDOW=1 "$dst"
    rm -rf "$work"
    """

    private let session: URLSession
    private let runner: CommandRunning
    private let fileManager: FileManager
    private let workRoot: URL
    private let brewPrefixes: [String]
    private let appDirectory: URL
    private let ditto: String
    private let shell: String
    private let brewOverride: String?

    public init(
        session: URLSession = .shared,
        runner: CommandRunning = ProcessRunner(),
        fileManager: FileManager = .default,
        workRoot: URL? = nil,
        brewPrefixes: [String] = ["/opt/homebrew", "/usr/local"],
        appDirectory: URL = URL(fileURLWithPath: "/Applications"),
        ditto: String? = nil,
        shell: String? = nil,
        brew: String? = nil
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.session = session
        self.runner = runner
        self.fileManager = fileManager
        self.workRoot = workRoot ?? fileManager.temporaryDirectory
        self.brewPrefixes = brewPrefixes
        self.appDirectory = appDirectory
        self.ditto = ditto ?? environment["GRANNY_DITTO"] ?? "/usr/bin/ditto"
        self.shell = shell ?? environment["GRANNY_SWAP_SHELL"] ?? "/bin/sh"
        self.brewOverride = brew ?? environment["GRANNY_BREW"]
    }

    /// Completion always lands on the main queue.
    public func install(
        version: String,
        currentBundle: URL,
        completion: @escaping (Result<Outcome, Error>) -> Void
    ) {
        if let brew = brewExecutable(for: currentBundle) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = runBrew(brew)
                DispatchQueue.main.async { completion(result) }
            }
        } else {
            prepareSwap(version: version, currentBundle: currentBundle, completion: completion)
        }
    }

    // MARK: - Homebrew

    /// Brew is only the right path when the running bundle is the artifact
    /// brew owns: the Caskroom copy itself (a symlinked install resolves
    /// there), or the standard appdir target brew replaces. A dev copy
    /// elsewhere must not upgrade an unrelated cask behind the user's back -
    /// it takes the zip path instead. `GRANNY_BREW` forces the brew path.
    func brewExecutable(for currentBundle: URL) -> String? {
        if let brewOverride, fileManager.isExecutableFile(atPath: brewOverride) {
            return brewOverride
        }
        let running = currentBundle.resolvingSymlinksInPath().standardizedFileURL
        let target = appDirectory.appendingPathComponent("granny.app")
            .resolvingSymlinksInPath().standardizedFileURL
        for prefix in brewPrefixes {
            let brew = prefix + "/bin/brew"
            guard fileManager.isExecutableFile(atPath: brew),
                  let caskApp = caskAppURL(prefix: prefix)
            else { continue }
            if running.path == caskApp.path
                || running.path.hasPrefix(caskApp.path + "/")
                || running.path == target.path
            {
                return brew
            }
        }
        return nil
    }

    /// The app inside the newest Caskroom version directory, if any.
    private func caskAppURL(prefix: String) -> URL? {
        let root = URL(fileURLWithPath: prefix + "/Caskroom/granny")
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        else { return nil }
        for versionDir in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let app = versionDir.appendingPathComponent("granny.app")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: app.path, isDirectory: &isDirectory),
               isDirectory.boolValue
            {
                return app.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return nil
    }

    private func runBrew(_ brew: String) -> Result<Outcome, Error> {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_CASK_OPTS"] = "--no-quarantine"
        for arguments in [["update"], ["upgrade", "--cask", "granny"]] {
            do {
                let result = try runner.run(brew, arguments: arguments, environment: environment)
                guard result.status == 0 else {
                    let tail = result.output.split(separator: "\n").suffix(3).joined(separator: " / ")
                    return .failure(UpdateError.brewFailed(tail))
                }
            } catch {
                return .failure(UpdateError.tool("\(error)"))
            }
        }
        return .success(.upgradedByBrew)
    }

    // MARK: - Release zip

    private func prepareSwap(
        version: String,
        currentBundle: URL,
        completion: @escaping (Result<Outcome, Error>) -> Void
    ) {
        guard currentBundle.pathExtension == "app",
              let zip = UpdateChecker.assetURL(version: version),
              let sha = UpdateChecker.assetURL(version: version, suffix: ".zip.sha256")
        else {
            completion(.failure(UpdateError.notWritable))
            return
        }

        let work = workRoot.appendingPathComponent("granny-update-\(UUID().uuidString)")
        Task {
            do {
                try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
                try await prepareSwapFiles(
                    version: version, zip: zip, sha: sha, currentBundle: currentBundle, work: work)
                // The helper owns `work` from here; it removes it after the swap.
                await MainActor.run { completion(.success(.willSwap)) }
            } catch {
                try? fileManager.removeItem(at: work)
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private func prepareSwapFiles(
        version: String,
        zip: URL,
        sha: URL,
        currentBundle: URL,
        work: URL
    ) async throws {
        let zipFile = work.appendingPathComponent("granny-\(version).zip")
        try await download(zip, to: zipFile)
        let shaFile = work.appendingPathComponent("granny-\(version).zip.sha256")
        try await download(sha, to: shaFile)

        let expected = try String(contentsOf: shaFile, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .first.map(String.init) ?? ""
        guard let actual = UpdateChecker.sha256(ofFileAt: zipFile.path),
              !expected.isEmpty,
              expected.caseInsensitiveCompare(actual) == .orderedSame
        else { throw UpdateError.checksum }

        let unpacked = work.appendingPathComponent("unpacked")
        let unpackedResult = try runner.run(
            ditto, arguments: ["-x", "-k", zipFile.path, unpacked.path], environment: nil)
        guard unpackedResult.status == 0 else { throw UpdateError.unpack }

        let newApp = unpacked.appendingPathComponent("granny.app")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: newApp.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw UpdateError.unpack }

        guard fileManager.isWritableFile(atPath: currentBundle.deletingLastPathComponent().path)
        else { throw UpdateError.notWritable }

        let script = work.appendingPathComponent("swap.sh")
        try Self.swapScript.write(to: script, atomically: true, encoding: .utf8)
        // Detached: the helper waits for granny to quit, and granny must not
        // wait for the helper.
        try runner.launch(
            shell,
            arguments: [
                script.path,
                String(ProcessInfo.processInfo.processIdentifier),
                newApp.path,
                currentBundle.path,
                work.path,
            ],
            environment: nil)
    }

    private func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.download((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try data.write(to: destination)
    }
}
