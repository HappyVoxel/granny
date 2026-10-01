import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// Checks GitHub Releases for a newer granny. The cask cannot update itself,
/// so the app tells the user (notification + menu item) and they run
/// `brew upgrade --cask granny`. Sparkle is the full auto-update route when
/// the project wants it.
public enum UpdateChecker {
    public static let repository = "HappyVoxel/granny-agent"

    public static func latestRelease(from data: Data) -> ReleaseInfo? {
        guard let root = JSON.dict(from: data),
              let tag = root["tag_name"] as? String,
              let urlString = root["html_url"] as? String,
              let url = URL(string: urlString)
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else { return nil }
        return ReleaseInfo(version: version, url: url)
    }

    /// Numeric, dot-separated comparison: 0.2.0 > 0.1.9, 1.0 == 1.0.0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let left = index < candidateParts.count ? candidateParts[index] : 0
            let right = index < currentParts.count ? currentParts[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Returns the newer release, or nil when up to date / offline / any error.
    public static func check(currentVersion: String, session: URLSession = .shared) async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("granny-agent", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let release = latestRelease(from: data),
                  isNewer(release.version, than: currentVersion)
            else { return nil }
            return release
        } catch {
            return nil
        }
    }
}
