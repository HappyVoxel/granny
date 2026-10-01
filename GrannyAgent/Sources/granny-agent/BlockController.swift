import Foundation
import GrannyCore

/// Applies and clears the hosts block.
///
/// Preferred path: the installed helper through its NOPASSWD sudoers entry
/// (no prompts). Fallback: the bundled helper through the standard macOS
/// authorization dialog, so blocking works before `install-helper.sh` has
/// ever run. Both failure paths surface as one notification.
final class BlockController {
    static let installedHelperPath = "/usr/local/libexec/granny/granny-helper"

    var onError: ((String) -> Void)?
    private var warnedMissing = false

    /// The helper that ships inside the app bundle, next to the executable.
    private var bundledHelperPath: String? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let candidate = executable.deletingLastPathComponent()
            .appendingPathComponent("granny-helper").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    func isBlocked() -> Bool {
        guard let hosts = try? String(contentsOf: GrannyPaths.hostsURL, encoding: .utf8) else { return false }
        return HostsFile.isBlocked(current: hosts)
    }

    /// True when the live hosts block does not match the desired domain set:
    /// nothing applied yet, or the config changed since the last apply.
    func needsApply(_ domains: [String]) -> Bool {
        guard isBlocked() else { return true }
        guard let data = try? Data(contentsOf: appliedFileURL),
              let applied = JSON.decode([String].self, from: data)
        else { return true }
        return Set(applied) != Set(domains)
    }

    private var appliedFileURL: URL {
        GrannyPaths.stateDir.appendingPathComponent("applied-block.json")
    }

    private func rememberApplied(_ domains: [String]) {
        guard let data = JSON.encode(domains) else { return }
        try? data.write(to: appliedFileURL)
    }

    private func forgetApplied() {
        try? FileManager.default.removeItem(at: appliedFileURL)
    }

    @discardableResult
    func apply(domains: [String]) -> Bool {
        guard let path = writeDomainsFile(domains) else { return false }
        let success = run(["apply", path])
        if success { rememberApplied(domains) }
        return success
    }

    @discardableResult
    func clear() -> Bool {
        let success = run(["clear"])
        if success { forgetApplied() }
        return success
    }

    private func run(_ arguments: [String]) -> Bool {
        if FileManager.default.isExecutableFile(atPath: Self.installedHelperPath) {
            if runProcess("/usr/bin/sudo", ["-n", Self.installedHelperPath] + arguments) {
                return true
            }
        }
        if let bundled = bundledHelperPath {
            let command = ([bundled] + arguments).map(Quoting.shell).joined(separator: " ")
            let script = "do shell script \(Quoting.appleScript(command)) with administrator privileges"
            if runProcess("/usr/bin/osascript", ["-e", script]) {
                return true
            }
        }
        if !warnedMissing {
            warnedMissing = true
            onError?(GrannyLines.helperMissing)
        }
        return false
    }

    private func runProcess(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func writeDomainsFile(_ domains: [String]) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("granny-domains-\(UUID().uuidString).json")
        guard let data = JSON.encode(domains) else { return nil }
        do {
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }
}
