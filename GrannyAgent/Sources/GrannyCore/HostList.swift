import Foundation

/// The settings lists store raw strings; these helpers turn what a user
/// types into the entries the engine matches, and back into tidy rows.
///
/// A bare host always gets its `www.` twin because /etc/hosts has no
/// wildcards and the rules' prefix matching is literal - `facebook.com`
/// alone would leave `www.facebook.com` open. The `www.` twin is hidden in
/// display (one row per site) and removed together with its bare host.
public enum HostList {
    /// User input to host: trims, lowercases, drops scheme, path, port and a
    /// leading `www.`. Returns nil when the input cannot be a host.
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text.contains("://") {
            guard let host = URL(string: text)?.host, !host.isEmpty else { return nil }
            text = host
        } else {
            text = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
            text = text.split(separator: ":", maxSplits: 1).first.map(String.init) ?? text
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix(".") else { return nil }
        return text
    }

    /// Entries for a host the user added: the host plus its `www.` twin.
    /// `prefix` is "" for the block list and "https://" for the allow list.
    public static func entries(forHost host: String, prefix: String = "") -> [String] {
        guard !host.hasPrefix("www.") else { return [prefix + host] }
        return [prefix + host, prefix + "www." + host]
    }

    /// The host an entry stands for.
    public static func host(of entry: String) -> String {
        if entry.contains("://"), let host = URL(string: entry)?.host { return host }
        return entry
    }

    /// Display rows: one per host, `www.` twin hidden when the bare host is
    /// present. Order preserved.
    public static func displayHosts(_ entries: [String]) -> [String] {
        let hosts = entries.map { host(of: $0) }
        let bare = Set(hosts.filter { !$0.hasPrefix("www.") })
        var seen = Set<String>()
        var rows: [String] = []
        for host in hosts {
            if host.hasPrefix("www."), bare.contains(String(host.dropFirst(4))) { continue }
            if seen.insert(host).inserted { rows.append(host) }
        }
        return rows
    }

    /// Removes a displayed host: its entry and its `www.` twin.
    public static func removing(host: String, from entries: [String]) -> [String] {
        let twin = host.hasPrefix("www.") ? String(host.dropFirst(4)) : "www." + host
        return entries.filter { entry in
            let entryHost = self.host(of: entry)
            return entryHost != host && entryHost != twin
        }
    }
}
