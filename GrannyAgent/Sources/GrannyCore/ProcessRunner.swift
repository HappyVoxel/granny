import Foundation

/// Runs a tool and returns its exit status and combined output. Injected so
/// the tests can drive the installer without real processes; the e2e suites
/// can override the tool paths through `GRANNY_*` variables.
public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public protocol CommandRunning: Sendable {
    /// Runs a tool to completion and returns its exit status and output.
    func run(_ executable: String, arguments: [String], environment: [String: String]?) throws -> CommandResult
    /// Starts a tool without waiting for it: the swap helper must outlive
    /// the app it is replacing.
    func launch(_ executable: String, arguments: [String], environment: [String: String]?) throws
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String], environment: [String: String]?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? "")
    }

    public func launch(_ executable: String, arguments: [String], environment: [String: String]?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
