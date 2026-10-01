import Foundation

public enum DecisionAction: String, Codable, Sendable {
    case allow, warn, block
    /// Not a verdict: the engine needs the page's real title/context before
    /// it can judge (the extension answers by waiting for the title and
    /// asking again). Only the model path ever returns this.
    case needContext = "need-context"
}

public struct Decision: Codable, Sendable {
    public var action: DecisionAction
    public var message: String?
    public var reason: String
    public var source: String

    public init(_ action: DecisionAction, message: String? = nil, reason: String, source: String) {
        self.action = action
        self.message = message
        self.reason = reason
        self.source = source
    }
}

/// Tier 1 of the decision engine: local, synchronous rules.
/// Returns nil when no rule matched; the caller then consults the model
/// tiers (unknown hosts included - granny watches new sites instead of
/// waving them through), or allows outright when no tier can answer.
public struct RulesEngine: Sendable {
    /// YouTube is special everywhere (rules, janitor): only Shorts are
    /// blocked; the rest of the site stays open as a research tool.
    public static let youtubeHost = "youtube.com"
    public static let shortsPath = "/shorts"

    public let config: GrannyConfig

    public init(config: GrannyConfig) {
        self.config = config
    }

    public func evaluate(urlString: String, tasks: [TaskItem], phase: Phase) -> Decision? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        if !phase.blocksActive {
            return Decision(.allow, reason: "phase \(phase.rawValue)", source: "rules")
        }

        let lower = urlString.lowercased()
        for prefix in config.alwaysAllowedURLPrefixes where lower.hasPrefix(prefix.lowercased()) {
            return Decision(.allow, reason: "always allowed", source: "rules")
        }

        let path = url.path.isEmpty ? "/" : url.path
        let openTasks = tasks.filter { !$0.done }

        // Exact surface match: purposeful access to an allowed path.
        for task in openTasks {
            for surface in task.allowedSurfaces where Self.matches(surface: surface, host: host, path: path) {
                return Decision(
                    .allow,
                    message: GrannyLines.surfaceAllow(task: task.title),
                    reason: "task surface \(surface)",
                    source: "rules")
            }
        }

        // The host is opened by a task but this path is outside the surface.
        for task in openTasks {
            for surface in task.allowedSurfaces {
                if Self.hostMatches(host, Self.host(ofSurface: surface)) {
                    return Decision(
                        .warn,
                        message: GrannyLines.offSurface(task: task.title),
                        reason: "outside surface \(surface)",
                        source: "rules")
                }
            }
        }

        if Self.hostMatches(host, Self.youtubeHost), path.lowercased().hasPrefix(Self.shortsPath) {
            return Decision(.block, message: GrannyLines.shorts, reason: "youtube shorts", source: "rules")
        }

        if config.blockedDomains.contains(where: { Self.hostMatches(host, $0) }) {
            return Decision(.block, message: GrannyLines.blocked(host: host), reason: "blocked domain", source: "rules")
        }

        if config.blockedPatterns.contains(where: { lower.contains($0.lowercased()) }) {
            return Decision(.block, message: GrannyLines.blocked(host: host), reason: "blocked pattern", source: "rules")
        }

        return nil
    }

    public static func host(ofSurface surface: String) -> String {
        String(surface.split(separator: "/", maxSplits: 1).first ?? "").lowercased()
    }

    public static func hostMatches(_ host: String, _ pattern: String) -> Bool {
        let p = pattern.lowercased()
        if p.hasPrefix("*.") { return host.hasSuffix(String(p.dropFirst())) }
        return host == p || host.hasSuffix("." + p)
    }

    /// Surface patterns are "host" or "host/path" with an optional trailing *.
    /// A path without a wildcard matches itself and anything below it. A
    /// trailing * on the host alone ("threads.com*") is tolerated and means
    /// the host plus its subdomains, like a bare host does.
    public static func matches(surface: String, host: String, path: String) -> Bool {
        let parts = surface.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var surfaceHost = String(parts[0]).lowercased()
        if surfaceHost.hasSuffix("*") { surfaceHost = String(surfaceHost.dropLast()) }
        guard !surfaceHost.isEmpty, hostMatches(host, surfaceHost) else { return false }
        guard parts.count == 2 else { return true }

        var patternPath = "/" + String(parts[1]).lowercased()
        let actual = path.lowercased()
        if patternPath.hasSuffix("*") {
            patternPath = String(patternPath.dropLast())
            return actual.hasPrefix(patternPath)
        }
        return actual == patternPath || actual.hasPrefix(patternPath + "/")
    }
}

/// YouTube is a research tool: the tab janitor never closes a YouTube tab
/// except Shorts. Content-level moderation of YouTube (movies vs music vs
/// study material) stays with the extension's overlays, not with tab
/// closing. Returns true when the janitor must leave the tab alone.
public func janitorNeverCloses(urlString: String) -> Bool {
    guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return true }
    if RulesEngine.hostMatches(host, RulesEngine.youtubeHost) {
        return !url.path.lowercased().hasPrefix(RulesEngine.shortsPath)
    }
    return false
}

/// Whether an open browser tab should be closed right now (the tab
/// janitor's rule): a rules-level block verdict against the current tasks
/// and phase. Unknown hosts and ambiguous content are left to the
/// extension's verdict; the janitor only closes what the rules already call
/// blocked. YouTube tabs are never closed except Shorts.
public func shouldCloseTab(
    urlString: String, config: GrannyConfig, tasks: [TaskItem], phase: Phase
) -> Bool {
    if janitorNeverCloses(urlString: urlString) { return false }
    let engine = RulesEngine(config: config)
    guard let decision = engine.evaluate(urlString: urlString, tasks: tasks, phase: phase) else {
        return false
    }
    return decision.action == .block
}

/// Whether a launching app should be killed while blocks are active.
public func shouldKill(bundleID: String, phase: Phase, entertainmentApps: [String]) -> Bool {
    phase.blocksActive && entertainmentApps.contains(bundleID)
}
