import Foundation

public struct LangfuseConfig: Codable, Sendable {
    public var baseURL: String
    public var publicKey: String
    public var secretKey: String

    public init(baseURL: String, publicKey: String, secretKey: String) {
        self.baseURL = baseURL
        self.publicKey = publicKey
        self.secretKey = secretKey
    }
}

public struct GrannyConfig: Codable, Sendable {
    public var openRouterKey: String?
    public var model: String
    /// Which provider serves the model tier; raw values live in
    /// `ModelProvider`, nil means the default.
    public var provider: String?
    /// Model for the streak encouragement line; nil keeps the free router
    /// (`OpenRouterClient.defaultStreakModel`). A tiny task: free is fine.
    public var streakModel: String?
    public var wakeHour: Int
    public var bedtimeHour: Int
    public var language: String
    /// Granny's stationery scheme; valid values live in `GrannyAppearance`.
    public var appearance: String
    /// Ask GitHub Releases once a day whether a newer granny exists.
    public var checkForUpdates: Bool
    public var speechEnabled: Bool
    public var voiceIdentifier: String?
    public var layaURL: String?
    public var layaKey: String?
    /// Optional checkpoint name for hosts that take one; empty means the
    /// language-based default.
    public var layaModel: String?
    /// Confidence gate for the Laya answer (0...1); nil keeps the default.
    /// Calibrations differ per host - the free Zaitlabs deployment answers
    /// far lower than the OpsCom console.
    public var layaMinConfidence: Double?
    /// Jev (TypeSafe's hosted classifier) speaks the same System One wire as
    /// Laya; used as the fast-classifier tier when Laya is not configured.
    public var jevURL: String?
    public var jevKey: String?
    /// Jev routed through OpenRouter (chat completions). Used automatically
    /// whenever an OpenRouter key is set, before the DeepSeek fallback.
    public var jevModel: String
    public var langfuse: LangfuseConfig?
    public var decidePort: Int
    public var token: String
    public var blockedDomains: [String]
    public var blockedPatterns: [String]
    public var dohDomains: [String]
    /// Hosts whose decision depends on the page content (title/channel):
    /// the engine asks for context instead of judging by URL alone.
    public var contextHosts: [String]
    public var alwaysAllowedURLPrefixes: [String]
    public var entertainmentApps: [String]

    public init(
        openRouterKey: String? = nil,
        model: String = "deepseek/deepseek-v4.1-flash",
        provider: String? = nil,
        streakModel: String? = nil,
        wakeHour: Int = 7,
        bedtimeHour: Int = 23,
        language: String = "en",
        appearance: String = "dark",
        checkForUpdates: Bool = true,
        speechEnabled: Bool = false,
        voiceIdentifier: String? = nil,
        layaURL: String? = nil,
        layaKey: String? = nil,
        layaModel: String? = nil,
        layaMinConfidence: Double? = nil,
        jevURL: String? = nil,
        jevKey: String? = nil,
        jevModel: String = "typesafe/jev-router",
        langfuse: LangfuseConfig? = nil,
        decidePort: Int = GrannyConfig.defaultDecidePort,
        token: String = UUID().uuidString,
        blockedDomains: [String] = GrannyConfig.defaultBlockedDomains,
        blockedPatterns: [String] = GrannyConfig.defaultBlockedPatterns,
        dohDomains: [String] = GrannyConfig.defaultDOHDomains,
        contextHosts: [String] = GrannyConfig.defaultContextHosts,
        alwaysAllowedURLPrefixes: [String] = GrannyConfig.defaultAlwaysAllowedPrefixes,
        entertainmentApps: [String] = GrannyConfig.defaultEntertainmentApps
    ) {
        self.openRouterKey = openRouterKey
        self.model = model
        self.provider = provider
        self.streakModel = streakModel
        self.wakeHour = wakeHour
        self.bedtimeHour = bedtimeHour
        self.language = language
        self.appearance = appearance
        self.checkForUpdates = checkForUpdates
        self.speechEnabled = speechEnabled
        self.voiceIdentifier = voiceIdentifier
        self.layaURL = layaURL
        self.layaKey = layaKey
        self.layaModel = layaModel
        self.layaMinConfidence = layaMinConfidence
        self.jevURL = jevURL
        self.jevKey = jevKey
        self.jevModel = jevModel
        self.langfuse = langfuse
        self.decidePort = decidePort
        self.token = token
        self.blockedDomains = blockedDomains
        self.blockedPatterns = blockedPatterns
        self.dohDomains = dohDomains
        self.contextHosts = contextHosts
        self.alwaysAllowedURLPrefixes = alwaysAllowedURLPrefixes
        self.entertainmentApps = entertainmentApps
    }

    public static let defaultBlockedDomains = [
        "facebook.com", "www.facebook.com", "m.facebook.com",
        "instagram.com", "www.instagram.com",
        "tiktok.com", "www.tiktok.com",
    ]

    // Substring patterns matched against the lowercased URL. Curated red
    // flags: streaming, adult, games, gambling. Everything else unknown is
    // judged by the classifier tiers at decision time.
    public static let defaultBlockedPatterns = [
        // streams / football
        "xoilac", "90phut", "bongdatv", "vipboxtv",
        // adult
        "porn", "xvideos", "xnxx", "xhamster", "redtube", "youporn",
        "onlyfans", "hentai", "fapello", "thothub",
        // games
        "gamevui", "y8.com", "poki", "miniclip", "crazygames", "friv",
        "kongregate", "newgrounds", "addictinggames", "armorgames", "trochoi",
        // gambling
        "188bet", "fb88", "fun88", "1xbet", "jun88", "sodo66", "casino", "baccarat",
    ]

    // Blocking the DoH and Private Relay endpoints pushes browsers back to
    // system DNS, which honors /etc/hosts.
    public static let defaultDOHDomains = [
        "dns.google", "cloudflare-dns.com", "mozilla.cloudflare-dns.com",
        "dns.quad9.net", "doh.opendns.com",
        "mask.icloud.com", "mask-h2.icloud.com", "mask-api.icloud.com",
        "mask-canary.icloud.com", "mask.apple-dns.net", "mask-t.apple-dns.net",
    ]

    public static let defaultContextHosts = [
        "youtube.com", "www.youtube.com", "m.youtube.com",
    ]

    /// Never blocked: focus music, the tracing dashboard the grandchild uses
    /// to watch granny work, and research/communication tools.
    public static let defaultAlwaysAllowedPrefixes = [
        "https://music.youtube.com",
        "https://github.com",
        "https://cloud.langfuse.com",
        "https://us.cloud.langfuse.com",
        "https://perplexity.ai",
        "https://www.perplexity.ai",
        "https://discord.com",
        "https://www.discord.com",
        "https://slack.com",
        "https://app.slack.com",
    ]

    public static let defaultEntertainmentApps = [
        "com.burbn.instagram",
        "com.zhiliaoapp.musically",
        "com.facebook.katana",
        "com.valvesoftware.steam",
        "com.epicgames.EpicGamesLauncher",
        "com.roblox.RobloxPlayer",
    ]

    /// Display names for the default entertainment apps. These are iOS
    /// bundle ids that rarely resolve on a Mac, so the settings list would
    /// otherwise show raw ids. Anything installed resolves through
    /// NSWorkspace first; unknown ids still fall back to the raw id.
    public static let defaultEntertainmentAppNames: [String: String] = [
        "com.burbn.instagram": "Instagram",
        "com.zhiliaoapp.musically": "TikTok",
        "com.facebook.katana": "Facebook",
        "com.valvesoftware.steam": "Steam",
        "com.epicgames.EpicGamesLauncher": "Epic Games Launcher",
        "com.roblox.RobloxPlayer": "Roblox",
    ]

    public static var `default`: GrannyConfig { GrannyConfig() }

    public static let defaultDecidePort = 47899
    public static let defaultLangfuseBaseURL = "https://cloud.langfuse.com"

    /// The decide port as a bindable value: a hand-edited config with an
    /// out-of-range number (0, negative, > 65535) falls back to the default
    /// instead of trapping.
    public var decidePortNumber: UInt16 {
        if let port = UInt16(exactly: decidePort), port > 0 { return port }
        return UInt16(clamping: GrannyConfig.defaultDecidePort)
    }

    // Decoding is per-field with defaults so new fields never break an
    // existing config file. A single wrong-typed field (a string where a
    // number belongs) is ignored instead of quarantining the whole file -
    // the user's keys must survive their typos.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GrannyConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil ?? fallback
        }
        func optional<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        openRouterKey = optional(.openRouterKey)
        model = value(.model, d.model)
        provider = optional(.provider)
        streakModel = optional(.streakModel)
        wakeHour = value(.wakeHour, d.wakeHour)
        bedtimeHour = value(.bedtimeHour, d.bedtimeHour)
        language = value(.language, d.language)
        appearance = value(.appearance, d.appearance)
        checkForUpdates = value(.checkForUpdates, d.checkForUpdates)
        speechEnabled = value(.speechEnabled, d.speechEnabled)
        voiceIdentifier = optional(.voiceIdentifier)
        layaURL = optional(.layaURL)
        layaKey = optional(.layaKey)
        layaModel = optional(.layaModel)
        layaMinConfidence = optional(.layaMinConfidence)
        jevURL = optional(.jevURL)
        jevKey = optional(.jevKey)
        jevModel = value(.jevModel, d.jevModel)
        langfuse = optional(.langfuse)
        decidePort = value(.decidePort, d.decidePort)
        token = value(.token, d.token)
        blockedDomains = value(.blockedDomains, d.blockedDomains)
        blockedPatterns = value(.blockedPatterns, d.blockedPatterns)
        dohDomains = value(.dohDomains, d.dohDomains)
        contextHosts = value(.contextHosts, d.contextHosts)
        alwaysAllowedURLPrefixes = value(.alwaysAllowedURLPrefixes, d.alwaysAllowedURLPrefixes)
        entertainmentApps = value(.entertainmentApps, d.entertainmentApps)
    }

    public static func load(from url: URL = GrannyPaths.configURL) -> GrannyConfig {
        GrannyPaths.ensureDirectories()
        guard FileManager.default.fileExists(atPath: url.path) else {
            var config = GrannyConfig()
            // Fresh install: speak the machine's language when granny knows it,
            // English otherwise. Existing configs keep what they hold.
            config.language = GrannyLanguage.preferred(from: Locale.preferredLanguages).rawValue
            try? config.save(to: url)
            return config
        }
        if let data = try? Data(contentsOf: url), let config = JSON.decode(GrannyConfig.self, from: data) {
            return config
        }
        // A corrupt file must never be overwritten: the user's keys and lists
        // live there. Keep the bytes for inspection and run on defaults; the
        // next explicit save writes a fresh file.
        let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: backup)
        var fallback = GrannyConfig()
        fallback.language = GrannyLanguage.preferred(from: Locale.preferredLanguages).rawValue
        return fallback
    }

    public func save(to url: URL = GrannyPaths.configURL) throws {
        guard let data = JSON.encode(self) else { return }
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
