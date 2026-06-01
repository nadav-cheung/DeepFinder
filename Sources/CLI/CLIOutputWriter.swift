import Foundation

// MARK: - CLIOutputWriter

/// Protocol for CLI output, enabling test injection.
///
/// Production writes to stdout/stderr. Tests capture output for assertions.
protocol CLIOutputWriter: Sendable {
    func write(_ text: String)
    func writeError(_ text: String)
}

// MARK: - StdoutWriter

/// Production CLI output: writes to stdout and stderr.
struct StdoutWriter: CLIOutputWriter {
    func write(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }

    func writeError(_ text: String) {
        fputs(text, stderr)
        fflush(stderr)
    }
}
