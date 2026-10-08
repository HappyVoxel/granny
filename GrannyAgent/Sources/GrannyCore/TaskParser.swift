import Foundation

public enum TaskParser {
    /// The engine's reading of an edited task, merged into the user's own.
    /// Surfaces come from the model unless the editor set them by hand; the
    /// purpose is rewritten whenever the user did not write one themselves -
    /// a stale purpose from the old wording is worse than the model's line.
    /// The id and the done flag survive.
    public static func refined(
        _ task: TaskItem, with refined: TaskItem, purposeEdited: Bool, surfacesEdited: Bool
    ) -> TaskItem {
        var merged = task
        if !surfacesEdited {
            merged.allowedSurfaces = refined.allowedSurfaces
        }
        if !purposeEdited, let purpose = refined.purpose, !purpose.isEmpty {
            merged.purpose = purpose
        }
        return merged
    }
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
        // The rules compare against URL.path only: a query or fragment would
        // make the surface match nothing, so it is cut here.
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        if text.hasSuffix("/") { text = String(text.dropLast()) }
        guard !text.isEmpty, !text.contains(" "), !text.contains("\t") else { return nil }
        // A surface is a host - prose must never become one.
        guard looksLikeHost(text) else { return nil }
        return canonicalSurface(text)
    }

    /// Explicit hosts/URLs inside a clarifying answer ("…: https://a.com/;
    /// b.com/x"). Deterministic and conservative: whatever the user pasted is
    /// the truth, and the model is never asked to retype a URL it could
    /// invent.
    public static func surfaces(in text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;()[]<>\"'`"))
        var found: [String] = []
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            guard let surface = normalizeSurface(token) else { continue }
            if !found.contains(surface) { found.append(surface) }
        }
        return found
    }

    /// A host carries a dot and plausible labels; a bare word never passes.
    static func looksLikeHost(_ surface: String) -> Bool {
        var host = String(surface.split(separator: "/", maxSplits: 1)[0])
        if host.hasSuffix("*") { host = String(host.dropLast()) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
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
