import Foundation

/// The appearance setting. Stored as its raw string in the config so old
/// files keep working; the enum is the single list of valid values.
public enum GrannyAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public static func resolve(_ raw: String) -> GrannyAppearance {
        GrannyAppearance(rawValue: raw) ?? .dark
    }
}
