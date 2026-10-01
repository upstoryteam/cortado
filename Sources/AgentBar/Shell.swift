import Foundation

/// Runs short command-line tools. Output is stdout and stderr together, trimmed.
nonisolated enum Shell {
    struct Result: Sendable {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String] = []) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: process.terminationStatus, output: output)
    }

    /// For commands that can take seconds (joining a network, an admin prompt).
    @concurrent
    static func runInBackground(_ executable: String, _ arguments: [String] = []) async -> Result {
        run(executable, arguments)
    }
}
