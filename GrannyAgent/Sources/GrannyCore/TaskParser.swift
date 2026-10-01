import Foundation

public enum TaskParser {
    /// Naive fast parse: split on ; , newline and infer allowed surfaces
    /// from keywords. The LLM intake pass refines this when a key exists.
    /// The bullet the notebook editor inserts; the parser strips it back.
    public static let bullet = "• "

    /// Leading list bullets ("• ", "- ", "* ") are stripped so the bulleted
    /// editor in the UI can feed straight into the parser.
    public static func parse(_ text: String) -> [TaskItem] {
        let separators = CharacterSet(charactersIn: ";\n,")
        let chunks = text.components(separatedBy: separators)
            .map { strippingBullet($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        return chunks.map { TaskItem(title: $0, allowedSurfaces: surfaces(for: $0)) }
    }

    static func strippingBullet(_ line: String) -> String {
        var value = line
        for prefix in [bullet, "•", "- ", "* ", "· "] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return value
    }

    public static func surfaces(for text: String) -> [String] {
        let t = text.lowercased()
        var out: [String] = []

        if contains(t, ["apply", "job", "ứng tuyển", "tuyển dụng", "cv ", "resume"]) {
            out += ["linkedin.com/jobs*", "linkedin.com/job*"]
        }
        if contains(t, ["quảng cáo", "ads", "advertis", "campaign"]) {
            out += ["facebook.com/adsmanager*", "adsmanager.facebook.com/*",
                    "business.facebook.com/*", "ads.tiktok.com/*"]
        }
        if t.contains("linkedin") || t.contains("connect") { out += ["linkedin.com/*"] }
        if contains(t, ["docs", "tài liệu", "viết bài"]) { out += ["docs.google.com/*"] }
        if t.contains("github") { out += ["github.com/*"] }
        if contains(t, ["mail", "email"]) { out += ["mail.google.com/*"] }
        if t.contains("figma") { out += ["figma.com/*"] }
        if contains(t, ["học", "đọc blog", "read", "study", "research"]) {
            out += ["medium.com/*", "arxiv.org/*", "news.ycombinator.com/*"]
        }
        return Array(Set(out)).sorted()
    }

    private static func contains(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// Domains that moved while the old name keeps redirecting, so the model
    /// still answers with the old one and the answer looks plausible. Curated
    /// and tiny on purpose; extend as cases appear.
    static let movedDomains: [String: String] = [
        "threads.net": "threads.com",
    ]

    /// Rewrites a surface's host through `movedDomains`, keeping the path and
    /// any trailing wildcard intact.
    public static func canonicalSurface(_ surface: String) -> String {
        let parts = surface.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var host = String(parts[0]).lowercased()
        var star = ""
        if host.hasSuffix("*") {
            star = "*"
            host = String(host.dropLast())
        }
        guard let moved = movedDomains[host] else { return surface }
        let rest = parts.count == 2 ? "/" + parts[1] : ""
        return moved + star + rest
    }

    /// User input to a surface pattern: trims, lowercases, drops the scheme
    /// and a bare trailing slash. Returns nil when the input cannot be a
    /// surface (empty, or containing whitespace).
    public static func normalizeSurface(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.hasSuffix("/") { text = String(text.dropLast()) }
        guard !text.isEmpty, !text.contains(" "), !text.contains("\t") else { return nil }
        return canonicalSurface(text)
    }
}

/// Result of the optional LLM intake pass.
public struct ParsedIntake: Sendable {
    public var tasks: [TaskItem]
    public var question: String?

    public init(tasks: [TaskItem], question: String? = nil) {
        self.tasks = tasks
        self.question = question
    }
}
