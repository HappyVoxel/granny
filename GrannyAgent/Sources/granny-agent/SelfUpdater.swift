import AppKit
import Foundation
import GrannyCore

/// Installs the release the update checker found. A Homebrew install goes
/// through `brew update` + `brew upgrade --cask granny`, so brew's
/// bookkeeping stays honest; anything else downloads the release zip, checks
/// its published sha256, and hands the swap to a small shell helper. The
/// helper waits for granny to quit, replaces the bundle and reopens it, so
/// nothing has to survive the quit inside this process.
final class SelfUpdater {
    enum Outcome {
        /// Brew did the swap; the app reopens itself the usual way.
        case upgradedByBrew
        /// The helper is queued; the app should just terminate.
        case willSwap
    }

    enum UpdateError: LocalizedError {
        case download(Int)
        case checksum
        case unpack
        case notWritable
        case brewFailed(String)

        var errorDescription: String? {
            switch self {
            case .download(let status):
                return "Download failed (HTTP \(status))."
            case .checksum:
                return "The downloaded archive failed its checksum."
            case .unpack:
                return "The downloaded archive did not contain granny.app."
            case .notWritable:
                return "This copy of granny cannot replace itself; install it with Homebrew instead."
            case .brewFailed(let output):
                return "brew upgrade failed: \(output)"
            }
        }
    }

    /// Runs after granny exits: old bundle aside, new bundle in, old bundle
    /// gone, app reopened - and the old bundle comes back if the swap fails.
    private static let swapScript = """
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

    func install(version: String, completion: @escaping (Result<Outcome, Error>) -> Void) {
        if let brew = Self.brewExecutable() {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.runBrew(brew)
                DispatchQueue.main.async { completion(result) }
            }
        } else {
            installFromZip(version: version, completion: completion)
        }
    }

    // MARK: - Homebrew

    /// Only a granny the cask owns is updated by brew; a dev/script copy is
    /// not in the Caskroom and takes the zip path.
    private static func brewExecutable() -> String? {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let brew = prefix + "/bin/brew"
            guard FileManager.default.isExecutableFile(atPath: brew),
                  FileManager.default.fileExists(atPath: prefix + "/Caskroom/granny")
            else { continue }
            return brew
        }
        return nil
    }

    private static func runBrew(_ brew: String) -> Result<Outcome, Error> {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_CASK_OPTS"] = "--no-quarantine"
        for arguments in [["update"], ["upgrade", "--cask", "granny"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = arguments
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return .failure(error)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let output = String(data: data, encoding: .utf8) ?? ""
                let tail = output.split(separator: "\n").suffix(3).joined(separator: " / ")
                return .failure(UpdateError.brewFailed(tail))
            }
        }
        return .success(.upgradedByBrew)
    }

    // MARK: - Release zip

    private func installFromZip(version: String, completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let zip = UpdateChecker.assetURL(version: version),
              let sha = UpdateChecker.assetURL(version: version, suffix: ".zip.sha256")
        else {
            completion(.failure(UpdateError.notWritable))
            return
        }
        Task {
            do {
                let outcome = try await Self.prepareSwap(version: version, zip: zip, sha: sha)
                await MainActor.run { completion(.success(outcome)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private static func prepareSwap(version: String, zip: URL, sha: URL) async throws -> Outcome {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("granny-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

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
        try runTool("/usr/bin/ditto", ["-x", "-k", zipFile.path, unpacked.path])
        let newApp = unpacked.appendingPathComponent("granny.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.unpack }

        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path)
        else { throw UpdateError.notWritable }

        let script = work.appendingPathComponent("swap.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            newApp.path,
            destination.path,
            work.path,
        ]
        try helper.run()
        return .willSwap
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.download((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    private static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.unpack }
    }
}
