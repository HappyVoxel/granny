import Foundation

/// Manages the granny block section inside a hosts file.
/// The same rendering rules as the Phase 0 shell prototype, in Swift.
public enum HostsFile {
    public static let markBegin = "# GRANNY-BEGIN (managed by granny-agent; do not edit)"
    public static let markEnd = "# GRANNY-END"

    public static func render(current: String, domains: [String]) -> String {
        var lines = stripLines(current)
        lines.append("")
        lines.append(markBegin)
        lines.append(contentsOf: domains.map { "127.0.0.1 \($0)" })
        lines.append(markEnd)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func strip(current: String) -> String {
        stripLines(current).joined(separator: "\n") + "\n"
    }

    public static func isBlocked(current: String) -> Bool {
        current.contains(markBegin)
    }

    public static func blockedDomainCount(current: String) -> Int {
        var count = 0
        var inside = false
        for line in current.split(separator: "\n") {
            let s = String(line)
            if s == markBegin { inside = true; continue }
            if s == markEnd { inside = false; continue }
            if inside && s.hasPrefix("127.0.0.1 ") { count += 1 }
        }
        return count
    }

    private static func stripLines(_ current: String) -> [String] {
        var out: [String] = []
        var skipping = false
        for line in current.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s == markBegin { skipping = true; continue }
            if skipping && s == markEnd { skipping = false; continue }
            if skipping { continue }
            out.append(s)
        }
        while let last = out.last, last.isEmpty { out.removeLast() }
        return out
    }
}
