import Foundation
import OSLog

// MARK: - ScanOptions

/// Options controlling how content scanning behaves.
struct ScanOptions: Sendable, Equatable {
    /// Whether the search is case-sensitive. Default is `false`.
    var caseSensitive: Bool

    /// Lines longer than this many characters are skipped to avoid
    /// pathological input (e.g. minified files). Default is `10000`.
    var maxLineLength: Int

    init(caseSensitive: Bool = false, maxLineLength: Int = Constants.ContentScanner.defaultMaxLineLength) {
        self.caseSensitive = caseSensitive
        self.maxLineLength = maxLineLength
    }
}

// MARK: - ContentMatch

/// A single line-level match found by content scanning.
struct ContentMatch: Sendable, Equatable {
    /// Absolute path of the file containing the match.
    let filePath: String
    /// 1-based line number where the match was found.
    let lineNumber: Int
    /// Full content of the matched line (without trailing newline).
    let lineContent: String
    /// Character range of the match within `lineContent`.
    let matchRange: Range<String.Index>
}

// MARK: - TextFileExtensions

/// Extensions considered safe to scan as text. Binary files are skipped.
/// Case-insensitive via `.lowercased()` comparison.
/// No cases exist — this enum is used only as a namespace for static members.
enum TextFileExtensions {
    static let whitelist: Set<String> = [
        "txt", "md", "swift", "py", "js", "json", "xml", "yaml", "yml",
        "csv", "log", "html", "css", "ts", "tsx", "jsx", "rb", "go",
        "rs", "java", "c", "h", "cpp", "hpp", "sh", "bash", "zsh",
        "toml", "ini", "cfg", "conf", "sql", "pl", "r", "lua",
        "vim", "el", "clj", "hs", "ml", "scala", "kt", "dart",
        "gradle", "makefile", "dockerfile", "gitignore", "editorconfig",
    ]

    /// Returns `true` if the given extension (without leading dot) is in the whitelist.
    static func isTextFile(_ ext: String?) -> Bool {
        guard let ext else { return false }
        return whitelist.contains(ext.lowercased())
    }
}

// MARK: - ContentScanner

/// Stateless scanner that searches a file's contents for a query string.
///
/// Reads files line-by-line, auto-detects encoding via BOM (UTF-8 BOM,
/// UTF-16 LE/BE), and yields all matches found. Files with extensions not
/// in the text-file whitelist are skipped.
enum ContentScanner: Sendable {

    // MARK: - Logging

    private static let logger = Logger(subsystem: Product.daemonSubsystem, category: "content-scan")

    // MARK: - Public API

    /// Scan a file at the given path for occurrences of `query`.
    ///
    /// - Parameters:
    ///   - path: Absolute file path to scan.
    ///   - query: Text to search for within the file (should be NFC-normalized by caller).
    ///   - options: Scan options (case sensitivity, max line length).
    /// - Returns: Array of `ContentMatch`, one per line containing the query.
    ///   Empty if the file does not exist, is not a text file, or contains no matches.
    static func scan(fileAtPath path: String, query: String, options: ScanOptions = ScanOptions()) -> [ContentMatch] {
        guard !query.isEmpty else { return [] }

        // Extension check
        let ext = (path as NSString).pathExtension
        guard TextFileExtensions.isTextFile(ext) else { return [] }

        // File must exist and be readable
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        // Read raw data
        guard let rawData = try? Data(contentsOf: url) else {
            Self.logger.debug("ContentScanner: failed to read data from \(path, privacy: .public) — file may be locked or have been deleted")
            return []
        }

        // Skip likely binary files: if the first N bytes contain a NUL byte, treat as binary
        let probeSize = min(rawData.count, Constants.Scan.binaryProbeSize)
        if probeSize > 0 {
            let probe = rawData[0..<probeSize]
            if probe.contains(where: { $0 == 0 }) {
                // Exception: UTF-16 files legitimately have NUL bytes
                if !hasUTF16BOM(rawData) {
                    return []
                }
            }
        }

        // Decode to string with encoding detection
        guard let (string, _) = decodeString(rawData) else { return [] }

        // Scan line by line
        return scanLines(of: string, filePath: path, query: query, options: options)
    }

    // MARK: - Internal

    /// Detect encoding from BOM and decode raw bytes to a Swift string.
    ///
    /// Handles: UTF-8 (with/without BOM), UTF-16 LE, UTF-16 BE.
    /// Falls back to UTF-8 if no BOM is found.
    private static func decodeString(_ data: Data) -> (String, String.Encoding)? {
        // UTF-8 BOM: EF BB BF
        if data.count >= 3,
           data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
            let stripped = data.subdata(in: 3..<data.count)
            if let str = String(data: stripped, encoding: .utf8) {
                return (str, .utf8)
            }
        }

        // UTF-16 LE BOM: FF FE
        if data.count >= 2 && data[0] == 0xFF && data[1] == 0xFE {
            if let str = String(data: data, encoding: .utf16LittleEndian) {
                return (str, .utf16LittleEndian)
            }
        }

        // UTF-16 BE BOM: FE FF
        if data.count >= 2 && data[0] == 0xFE && data[1] == 0xFF {
            if let str = String(data: data, encoding: .utf16BigEndian) {
                return (str, .utf16BigEndian)
            }
        }

        // No BOM: try UTF-8 (most common case)
        if let str = String(data: data, encoding: .utf8) {
            return (str, .utf8)
        }

        return nil
    }

    /// Check if the data starts with a UTF-16 BOM.
    private static func hasUTF16BOM(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return (data[0] == 0xFF && data[1] == 0xFE) ||
               (data[0] == 0xFE && data[1] == 0xFF)
    }

    /// Scan each line of a string for the query, collecting matches.
    private static func scanLines(
        of content: String,
        filePath: String,
        query: String,
        options: ScanOptions
    ) -> [ContentMatch] {
        var matches: [ContentMatch] = []
        var lineNumber = 0

        var lineStart = content.startIndex
        while let newlineRange = content[lineStart...].range(of: "\n", options: .literal) {
            lineNumber += 1
            let lineEnd = newlineRange.lowerBound
            let line = String(content[lineStart..<lineEnd])

            if line.count <= options.maxLineLength {
                searchInLine(line, filePath: filePath, lineNumber: lineNumber, query: query, options: options, into: &matches)
            }

            lineStart = newlineRange.upperBound
        }

        // Last line (no trailing newline)
        if lineStart < content.endIndex {
            lineNumber += 1
            let line = String(content[lineStart...])
            if line.count <= options.maxLineLength {
                searchInLine(line, filePath: filePath, lineNumber: lineNumber, query: query, options: options, into: &matches)
            }
        }

        return matches
    }

    /// Find all occurrences of `query` in a single line and append matches.
    private static func searchInLine(
        _ line: String,
        filePath: String,
        lineNumber: Int,
        query: String,
        options: ScanOptions,
        into matches: inout [ContentMatch]
    ) {
        let searchOptions: String.CompareOptions = options.caseSensitive ? .literal : [.literal, .caseInsensitive]

        var searchStart = line.startIndex
        while let range = line.range(of: query, options: searchOptions, range: searchStart..<line.endIndex) {
            matches.append(ContentMatch(
                filePath: filePath,
                lineNumber: lineNumber,
                lineContent: line,
                matchRange: range
            ))
            searchStart = range.upperBound
        }
    }
}
