import Foundation

/// What the browser knows about the page being opened. The extension fills
/// this in as far as it can at decision time; the model tier judges the
/// content from it, not just the domain.
public struct PageContext: Sendable {
    public var url: String
    public var title: String?
    /// YouTube channel/author, when the page exposes it.
    public var channel: String?
    /// Meta description / og:description snippet.
    public var description: String?
    /// Coarse page kind reported by the extension: "video", "shorts",
    /// "music", "youtube", "page".
    public var kind: String?

    public init(
        url: String,
        title: String? = nil,
        channel: String? = nil,
        description: String? = nil,
        kind: String? = nil
    ) {
        self.url = url
        self.title = title
        self.channel = channel
        self.description = description
        self.kind = kind
    }

    /// True when the title carries actual content. A browser's placeholder
    /// title ("YouTube" before the watch page renders) is not a signal: the
    /// engine must ask for context instead of judging - and caching - the
    /// placeholder.
    public var hasContentSignal: Bool {
        let title = (self.title ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return false }
        let generic = ["youtube", "youtube music"]
        return !generic.contains(title.lowercased())
    }
}
