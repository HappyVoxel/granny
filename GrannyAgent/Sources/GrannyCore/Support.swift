import Foundation

public enum GrannyPaths {
    public static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment[GrannyEnv.configFile] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/granny/config.json")
    }

    public static var stateDir: URL {
        if let override = ProcessInfo.processInfo.environment[GrannyEnv.stateDir] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/granny", isDirectory: true)
    }

    public static var stateURL: URL {
        stateDir.appendingPathComponent("state.json")
    }

    /// The live hosts file. The override lets the e2e suites point the agent
    /// (and the helper) at a sandbox copy.
    public static var hostsURL: URL {
        if let override = ProcessInfo.processInfo.environment[GrannyEnv.hostsFile] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: "/etc/hosts")
    }

    public static func ensureDirectories() {
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }
}

public func dayString(_ date: Date, calendar: Calendar = .current) -> String {
    let comps = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
}

public enum JSON {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    public static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(value)
    }

    public static func dict(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func data(from object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
