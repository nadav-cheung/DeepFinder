// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderServices

// MARK: - CLIOutputWriter

/// Protocol for CLI output, enabling test injection.
///
/// Production writes to stdout/stderr. Tests capture output for assertions.
public protocol CLIOutputWriter: Sendable {
    func write(_ text: String)
    func writeError(_ text: String)
}

// MARK: - StdoutWriter

/// Production CLI output: writes to stdout and stderr.
public struct StdoutWriter: CLIOutputWriter {
    public init() {}
    public func write(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }

    public func writeError(_ text: String) {
        fputs(text, stderr)
        fflush(stderr)
    }
}
