import Foundation

// MARK: - CLIOptions

/// Parsed CLI options from command-line arguments.
struct CLIOptions: Sendable, Equatable {
    /// Search query. `nil` means no query was provided (triggers REPL in v0.6).
    var query: String?
    /// Output results as JSON (--json).
    var jsonOutput: Bool = false
    /// Output results separated by null bytes (--0).
    var nullOutput: Bool = false
    /// Sort results by the given criterion.
    var sort: SortOption?
    /// Maximum number of results to return.
    var limit: Int?
    /// Number of results to skip.
    var offset: Int?
    /// Reverse sort order.
    var reverse: Bool = false
    /// Verbose output.
    var verbose: Bool = false
    /// Show help text and exit.
    var showHelp: Bool = false
    /// Show version and exit.
    var showVersion: Bool = false
    /// Enable HTTP serve mode (--serve).
    var serveMode: Bool = false
    /// Port for HTTP serve mode (--port). Default 7654.
    var port: Int = 7654
    /// Subcommand for v0.7+ (e.g. "daemon", "config").
    var subcommand: String?
}

// MARK: - SortOption

/// Sort criteria for search results.
///
/// Used by `--sort name|size|date` and mapped to `SortCriterion`
/// in the search layer.
enum SortOption: String, Sendable, Equatable, CaseIterable {
    case name
    case size
    case date
}

// MARK: - CLIError

/// Errors produced during argument parsing.
enum CLIError: Error, Sendable, Equatable, CustomStringConvertible {
    /// An unrecognized flag was provided (e.g. `--bogus`).
    case unknownFlag(String)
    /// A flag that requires a value was given without one (e.g. `--limit` at end of args).
    case missingValue(flag: String)
    /// A flag received an invalid value (e.g. `--limit abc` or `--sort color`).
    case invalidValue(flag: String, value: String)

    var description: String {
        switch self {
        case .unknownFlag(let flag):
            return "unknown option: \(flag)"
        case .missingValue(let flag):
            return "\(flag) requires a value"
        case .invalidValue(let flag, let value):
            return "\(flag): invalid value '\(value)'"
        }
    }
}

// MARK: - ArgParser

/// Parses command-line arguments into `CLIOptions`.
///
/// Supports:
/// - Positional query argument
/// - `--json`, `--0`, `--reverse`, `--verbose`, `--help`, `--version` (boolean flags)
/// - `--sort name|size|date`, `--limit N`, `--offset M` (value flags)
/// - Subcommand routing: first non-flag argument when no query is set becomes subcommand
struct ArgParser {
    /// Parse an argument list (excluding the program name) into `CLIOptions`.
    static func parse(_ args: [String]) throws -> CLIOptions {
        var opts = CLIOptions()
        var i = 0

        while i < args.count {
            let arg = args[i]

            if arg.hasPrefix("--") {
                switch arg {
                // Boolean flags
                case "--json":
                    opts.jsonOutput = true
                case "--0":
                    opts.nullOutput = true
                case "--reverse":
                    opts.reverse = true
                case "--verbose":
                    opts.verbose = true
                case "--help":
                    opts.showHelp = true
                case "--version":
                    opts.showVersion = true
                case "--serve":
                    opts.serveMode = true

                // Value flags
                case "--sort":
                    let value = try nextValue(after: i, in: args, flag: arg)
                    guard let sortOpt = SortOption(rawValue: value) else {
                        throw CLIError.invalidValue(flag: "--sort", value: value)
                    }
                    opts.sort = sortOpt
                    i += 1

                case "--limit":
                    let value = try nextValue(after: i, in: args, flag: arg)
                    guard let n = Int(value), n >= 0 else {
                        throw CLIError.invalidValue(flag: "--limit", value: value)
                    }
                    opts.limit = n
                    i += 1

                case "--offset":
                    let value = try nextValue(after: i, in: args, flag: arg)
                    guard let n = Int(value), n >= 0 else {
                        throw CLIError.invalidValue(flag: "--offset", value: value)
                    }
                    opts.offset = n
                    i += 1

                case "--port":
                    let value = try nextValue(after: i, in: args, flag: arg)
                    guard let n = Int(value), n > 0, n <= 65535 else {
                        throw CLIError.invalidValue(flag: "--port", value: value)
                    }
                    opts.port = n
                    i += 1

                default:
                    throw CLIError.unknownFlag(arg)
                }
            } else {
                // Positional argument: first one becomes query, next becomes subcommand.
                if opts.query == nil {
                    opts.query = arg
                } else if opts.subcommand == nil {
                    opts.subcommand = arg
                }
            }

            i += 1
        }

        return opts
    }

    /// Returns the argument at `index + 1`, or throws if there is none.
    private static func nextValue(after index: Int, in args: [String], flag: String) throws -> String {
        let next = index + 1
        guard next < args.count else {
            throw CLIError.missingValue(flag: flag)
        }
        return args[next]
    }

    // MARK: - Help Text

    /// Complete usage documentation.
    static let helpText = """
        USAGE
          deepfinder [options] [query]
          deepfinder <subcommand> [options]

        DESCRIPTION
          DeepFinder — instant file search for macOS.

          When invoked with a query, performs a single search and exits.
          When invoked without a query, enters interactive REPL mode.

        OPTIONS
          --json              Output results as JSON
          --0                 Output results separated by null bytes (for xargs -0)
          --sort <field>      Sort by: name, size, date
          --limit <n>         Maximum number of results
          --offset <n>        Number of results to skip
          --reverse           Reverse sort order
          --verbose           Show match type and relevance score per result
          --serve             Start HTTP search service (no query needed)
          --port <n>          Port for --serve mode (default: 7654)
          --help              Show this help text
          --version           Show version

        SUBCOMMANDS
          daemon start        Start the background daemon
          daemon stop         Stop the background daemon
          daemon restart      Restart the daemon
          daemon status       Show daemon status (PID, uptime, file count)
          config get <key>    Get a configuration value
          config set <key> <val>  Set a configuration value
          config list         List all configuration values
          config reset        Reset all configuration to defaults
          install             Install LaunchAgent for auto-start on login
          uninstall           Remove LaunchAgent

        EXAMPLES
          deepfinder hello.txt              Search for "hello.txt"
          deepfinder --json "*.pdf"         Search for PDFs, JSON output
          deepfinder --limit 10 --sort date "report"
                                            Latest 10 results matching "report"
          deepfinder --0 "photo"            Null-delimited output for scripting
          deepfinder --serve --port 8080    Start HTTP search service on port 8080
          deepfinder daemon start           Start the background daemon

        EXIT CODES
          0   Success
          1   No results found
          2   Daemon error
          3   Query error
        """
}
