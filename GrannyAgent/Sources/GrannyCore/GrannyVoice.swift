import Foundation

/// Picks granny's TTS voice for her speaking language.
public enum GrannyVoice {
    public struct Voice: Equatable, Sendable {
        public let name: String
        public let locale: String

        public init(name: String, locale: String) {
            self.name = name
            self.locale = locale
        }
    }

    /// The voices granny prefers per language, when installed.
    public static let preferredNames: [String: String] = [
        "vi": "Linh",
        "en": "Samantha",
        "fi": "Grandma",
    ]

    /// Parses `say -v '?'` output lines like
    /// `Linh (Vietnamese (Vietnam)) vi_VN    # Xin chào! ...`
    /// into base-name + locale pairs.
    public static func parse(_ voicesOutput: String) -> [Voice] {
        voicesOutput.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard let hash = line.firstIndex(of: "#") else { return nil }
            let tokens = line[..<hash].split(separator: " ")
            guard let locale = tokens.last, locale.count == 5, locale.contains("_") else { return nil }
            let fullName = tokens.dropLast().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !fullName.isEmpty else { return nil }
            let baseName = fullName.components(separatedBy: " (").first ?? fullName
            return Voice(name: baseName, locale: String(locale))
        }
    }

    /// The voice to hand to `say -v`, or nil to let `say` use the system
    /// default. A configured voice is honored only when its locale matches
    /// the language; otherwise the language's preferred voice, then any
    /// voice of that language.
    public static func resolve(configured: String?, language: String, voices: [Voice]) -> String? {
        let lang = (GrannyLanguage(code: language) ?? .en).rawValue

        if let configured, !configured.isEmpty,
           let match = voices.first(where: { $0.name == configured && $0.locale.hasPrefix(lang) }) {
            return match.name
        }
        if let preferred = preferredNames[lang],
           let match = voices.first(where: { $0.name == preferred && $0.locale.hasPrefix(lang) }) {
            return match.name
        }
        return voices.first(where: { $0.locale.hasPrefix(lang) })?.name
    }
}
