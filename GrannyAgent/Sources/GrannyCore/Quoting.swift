import Foundation

/// Quoting for command strings handed to shells and AppleScript.
public enum Quoting {
    /// Single-quote a value for /bin/sh (single quotes safely escape
    /// everything except single quotes themselves).
    public static func shell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a value for embedding inside an AppleScript string literal.
    /// Backslash, quote and newlines: a raw newline inside the literal is
    /// accepted by some parsers and rejected by others, so it becomes \n.
    public static func appleScript(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
