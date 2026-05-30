import Foundation

// MARK: - TerminalFormatter

/// Formats search results for terminal output.
///
/// Three output modes:
/// - **JSON** (`--json`): JSON array of `SearchResult`.
/// - **NUL** (`--0`): file paths separated by `\\0` for scripting.
/// - **ANSI** (default): human-readable with optional colors and match highlights.
enum TerminalFormatter {

    // MARK: - Public API

    /// Format an array of search results according to the given CLI options.
    ///
    /// - Parameters:
    ///   - results: Search results to format.
    ///   - options: Parsed CLI options controlling output mode.
    ///   - isTerminal: Whether stdout is a terminal. Defaults to `isatty()`.
    /// - Returns: Formatted string ready to write to stdout.
    static func format(
        _ results: [SearchResult],
        options: CLIOptions,
        isTerminal: Bool = isatty()
    ) -> String {
        if options.jsonOutput {
            return formatJSON(results)
        }
        if options.nullOutput {
            return formatNUL(results)
        }
        return formatANSI(results, options: options, isTerminal: isTerminal)
    }

    /// Returns `true` if stdout is attached to a terminal.
    static func isatty() -> Bool {
        Foundation.isatty(STDOUT_FILENO) != 0
    }

    /// Highlights all case-insensitive occurrences of `query` in `text`
    /// with ANSI bold + color codes.
    ///
    /// - Parameters:
    ///   - text: Source text.
    ///   - query: Substring to highlight.
    ///   - colorCode: ANSI color code (default yellow "33").
    /// - Returns: Text with ANSI escape sequences wrapping each match.
    static func highlightMatches(
        in text: String,
        query: String,
        colorCode: String = "33"
    ) -> String {
        guard !query.isEmpty else { return text }

        let lowercased = text.lowercased()
        let queryLower = query.lowercased()

        var result = ""
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let searchRange = currentIndex..<text.endIndex
            guard let range = lowercased.range(of: queryLower, range: searchRange) else {
                result += text[currentIndex...]
                break
            }

            // Append text before match
            result += text[currentIndex..<range.lowerBound]

            // Append highlighted match (use original casing from `text`)
            // Selective reset: 22 = bold off, 39 = default foreground color.
            // Avoids [0m which resets ALL attributes (would clobber surrounding styles).
            let originalMatch = text[range]
            result += "\u{1B}[1m\u{1B}[\(colorCode)m\(originalMatch)\u{1B}[22m\u{1B}[39m"

            currentIndex = range.upperBound
        }

        return result
    }

    /// Replaces the user's home directory prefix with `~/`.
    static func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        let relative = path.dropFirst(home.count)
        // Avoid double-slash when home path already ends with "/"
        if relative.hasPrefix("/") {
            return "~" + relative
        }
        return "~/" + relative
    }

    /// Formats a byte count as a human-readable string (B / KB / MB / GB).
    static func formatFileSize(_ bytes: Int64) -> String {
        let gb: Int64 = 1_073_741_824
        let mb: Int64 = 1_048_576
        let kb: Int64 = 1024

        if bytes >= gb {
            let value = Double(bytes) / Double(gb)
            if value == floor(value) {
                return "\(Int(value)) GB"
            }
            return "\(String(format: "%.1f", value)) GB"
        }
        if bytes >= mb {
            let value = Double(bytes) / Double(mb)
            if value == floor(value) {
                return "\(Int(value)) MB"
            }
            return "\(String(format: "%.1f", value)) MB"
        }
        if bytes >= kb {
            let value = Double(bytes) / Double(kb)
            if value == floor(value) {
                return "\(Int(value)) KB"
            }
            return "\(String(format: "%.1f", value)) KB"
        }
        return "\(bytes) B"
    }

    /// Shared date formatter for consistent output across all results.
    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    // MARK: - Private Formatters

    /// Format results as a JSON array of `SearchResult` objects.
    ///
    /// Uses sorted keys for deterministic output. Returns `"[]"` on encoding failure.
    private static func formatJSON(_ results: [SearchResult]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(results) else {
            return "[]"
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Format results as NUL-separated file paths for scripting (`xargs -0`).
    private static func formatNUL(_ results: [SearchResult]) -> String {
        let paths = results.map(\.record.path)
        return paths.joined(separator: "\0") + "\0"
    }

    /// Format results as human-readable ANSI-colored lines.
    ///
    /// When `isTerminal` is false, strips all ANSI escape codes.
    private static func formatANSI(
        _ results: [SearchResult],
        options: CLIOptions,
        isTerminal: Bool
    ) -> String {
        guard !results.isEmpty else { return "" }

        let query = options.query ?? ""
        let lines = results.map { result in
            formatSingleResult(result, query: query, options: options, isTerminal: isTerminal)
        }
        return lines.joined(separator: "\n")
    }

    /// Format a single search result as one line.
    ///
    /// Layout: `filename path size date` with optional verbose metadata.
    /// When `isTerminal` is true, the filename has query-match highlights
    /// and the metadata portion is dimmed.
    private static func formatSingleResult(
        _ result: SearchResult,
        query: String,
        options: CLIOptions,
        isTerminal: Bool
    ) -> String {
        let record = result.record
        let fileName = record.originalName

        let displayName: String
        if isTerminal && !query.isEmpty {
            displayName = highlightMatches(in: fileName, query: query)
        } else {
            displayName = fileName
        }

        let displayPath = shortenPath(record.path)
        let sizeStr = formatFileSize(record.size)

        let dateStr = sharedDateFormatter.string(from: record.modifiedAt)

        // Verbose extras
        var extras = ""
        if options.verbose {
            let matchLabel = "[\(result.matchType)]"
            extras += " \(matchLabel)"
            extras += " score:\(String(format: "%.2f", result.score))"
        }

        if isTerminal {
            // Colored output
            let dim = "\u{1B}[2m"
            let reset = "\u{1B}[0m"
            return "\(displayName) \(dim)\(displayPath) \(sizeStr) \(dateStr)\(reset)\(extras)"
        } else {
            // Plain output — filename, path, size, date
            return "\(fileName) \(displayPath) \(sizeStr) \(dateStr)\(extras)"
        }
    }
}
