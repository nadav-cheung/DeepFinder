// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// # CLI Module
///
/// The user-facing command-line interface for DeepFinder. Parses arguments,
/// communicates with the daemon over IPC, and formats results for terminal output.
///
/// ## Components
/// - ``CLIMain`` -- top-level entry point: argument parsing, dispatch to REPL or single-shot
/// - ``ArgParser`` -- command-line argument parser (zero external dependencies)
/// - ``SingleShot`` -- one-shot query execution and result formatting
/// - ``REPL`` -- interactive read-eval-print loop using Darwin.readline
/// - ``REPLCommands`` -- built-in REPL commands (:help, :stats, :open, :reveal, etc.)
/// - ``REPLHistory`` -- persistent command history across sessions
/// - ``TerminalFormatter`` -- ANSI-colored terminal output (auto-disables when piped)
/// - ``IPCClientProtocol`` -- protocol abstraction for IPC communication (testable)
/// - ``DaemonCommands`` -- daemon lifecycle commands (start, stop, restart, status)
/// - ``ConfigCommands`` -- runtime configuration get/set via CLI
/// - ``InstallCommands`` -- LaunchAgent installation and shell completion setup
/// - ``ServeMode`` -- run daemon in foreground for development/debugging
/// - ``FuzzyCorrection`` -- suggest similar query terms when no results found
///
/// ## Usage
/// ```bash
/// deepfinder "query"              # Single-shot search
/// deepfinder                      # Interactive REPL (v0.6+)
/// deepfinder --json "query"       # JSON output for scripting
/// deepfinder --help               # Show help
/// deepfinder daemon start         # Start background daemon
/// ```
///
/// ## Exit Codes
/// - 0: success
/// - 1: no results found
/// - 2: daemon error
/// - 3: query error
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderServices

// MARK: - CLIExitCode

/// Exit codes for the DeepFinder CLI.
///
/// These match the documented exit codes in `--help`:
/// - 0 = success
/// - 1 = no results found
/// - 2 = daemon error
/// - 3 = query error
public enum CLIExitCode: Int32, Sendable, Equatable {
    case success = 0
    case noResults = 1
    case daemonError = 2
    case queryError = 3
}

// MARK: - CLIOutput

/// Output from a CLI run, separated into stdout and stderr streams.
public struct CLIOutput: Sendable {
    public var stdout: String = ""
    public var stderr: String = ""
}

// MARK: - CLIMain

/// Top-level entry point for the DeepFinder CLI.
///
/// Parses arguments, handles meta-flags (--help, --version),
/// dispatches to subcommand runners, REPL, or single-shot query mode,
/// and returns the appropriate exit code along with collected output.
///
/// This struct performs no I/O — it returns all output as strings.
/// The caller (the `@main` entry point) is responsible for writing
/// to the actual stdout/stderr file descriptors.
public struct CLIMain {

    /// Public entry point for executable entry points.
    /// Calls through to the internal run with default clientProvider.
    public static func run(
        args: [String]
    ) async -> (output: CLIOutput, exitCode: CLIExitCode) {
        let result = await run(args: args, clientProvider: nil)

        // REPL mode: when stdin is a terminal, launch the interactive REPL.
        // The REPL writes directly to stdout/stderr (not to CLIOutput).
        // When stdin is not a tty (test harness, pipe), the REPL hint
        // message is returned via CLIOutput for test compatibility.
        if result.exitCode == .success && result.output._replHint {
            if isatty(STDIN_FILENO) != 0 {
                do {
                    let client = IPCClient(socketPath: Product.socketPath)
                    try await client.ensureDaemonRunning()
                    let repl = REPL(client: client)
                    await repl.run()
                    return (CLIOutput(), .success)
                } catch {
                    return (
                        CLIOutput(stderr: "Error: could not start daemon — \(error.localizedDescription)\n"),
                        .daemonError
                    )
                }
            }
        }

        return result
    }

    /// Run the CLI with the given argument list and optional IPC client injection.
    ///
    /// - Parameters:
    ///   - args: Command-line arguments excluding the program name
    ///     (i.e. `CommandLine.arguments.dropFirst()`).
    ///   - clientProvider: IPC client to use. Defaults to a real `IPCClient`.
    ///     Inject a `MockIPCClient` in tests to avoid needing a live daemon.
    /// - Returns: Tuple of (collected output, exit code).
    public static func run(
        args: [String],
        clientProvider: (any IPCClientProtocol)? = nil
    ) async -> (output: CLIOutput, exitCode: CLIExitCode) {
        // 1. Parse arguments
        let options: CLIOptions
        do {
            options = try ArgParser.parse(args)
        } catch let error as CLIError {
            return (CLIOutput(stderr: "Error: \(error)\n"), .queryError)
        } catch {
            return (CLIOutput(stderr: "Error: \(error)\n"), .queryError)
        }

        // 2. Handle --help
        if options.showHelp {
            return (CLIOutput(stdout: ArgParser.helpText), .success)
        }

        // 3. Handle --version
        if options.showVersion {
            return (CLIOutput(stdout: "\(Product.name) \(Product.version)\n"), .success)
        }

        // 4. Handle --serve mode
        if options.serveMode {
            return await ServeMode.run(options: options, clientProvider: clientProvider)
        }

        // 5. Handle subcommand dispatch
        // ArgParser assigns first positional to query, second to subcommand.
        // E.g. "daemon start" → query="daemon", subcommand="start"
        //      "config set key val" → query="config", subcommand="set"
        //      "install" → query="install", subcommand=nil
        if let query = options.query {
            let positionalArgs = Self.extractPositionalArgs(from: args)

            switch query {
            case "daemon":
                return await handleDaemonSubcommand(
                    action: options.subcommand,
                    clientProvider: clientProvider
                )

            case "config":
                return await handleConfigSubcommand(
                    action: options.subcommand,
                    extraArgs: Array(positionalArgs.dropFirst(2)),
                    clientProvider: clientProvider
                )

            case "install":
                return handleInstallSubcommand()

            case "uninstall":
                return handleUninstallSubcommand()

            default:
                break // Not a subcommand — treat as search query
            }
        }

        // 6. Handle --bookmark NAME: resolve the saved bookmark's query from the
        //    daemon and run it as a single-shot search (REQ-1.3-01).
        if let bookmarkName = options.bookmark {
            return await handleBookmarkRun(
                name: bookmarkName,
                options: options,
                clientProvider: clientProvider
            )
        }

        // 7. Handle no query → REPL mode
        guard let query = options.query else {
            return (
                CLIOutput(stdout: "\(Product.name) \(Product.version) — interactive REPL\n"),
                .success
            )
        }

        // 8. Create IPC client
        let client: any IPCClientProtocol
        if let provider = clientProvider {
            client = provider
        } else {
            let ipcClient = IPCClient(socketPath: Product.socketPath)

            // Auto-spawn daemon if needed
            do {
                try await ipcClient.ensureDaemonRunning()
            } catch {
                return (
                    CLIOutput(stderr: "Error: could not start daemon — \(error.localizedDescription)\n"),
                    .daemonError
                )
            }

            client = ipcClient
        }

        // 9. Execute single-shot query
        let (resultOutput, exitCode) = await SingleShot.execute(
            query: query,
            options: options,
            client: client
        )

        return (resultOutput, exitCode)
    }

    // MARK: - Bookmark Run (--bookmark NAME)

    /// Handle `--bookmark NAME` single-shot mode: create the IPC client, resolve
    /// the named bookmark's stored query from the daemon, then run it as a
    /// normal single-shot search. An unknown bookmark name is a user error.
    private static func handleBookmarkRun(
        name: String,
        options: CLIOptions,
        clientProvider: (any IPCClientProtocol)?
    ) async -> (CLIOutput, CLIExitCode) {
        // Create IPC client (auto-spawn daemon).
        let client: any IPCClientProtocol
        if let provider = clientProvider {
            client = provider
        } else {
            let ipcClient = IPCClient(socketPath: Product.socketPath)
            do {
                try await ipcClient.ensureDaemonRunning()
            } catch {
                return (
                    CLIOutput(stderr: "Error: could not start daemon — \(error.localizedDescription)\n"),
                    .daemonError
                )
            }
            client = ipcClient
        }

        // Fetch the bookmark list and find the one matching `name`.
        // Equality is by `id`, so names may collide — the first match wins.
        let response: IPCResponse
        do {
            response = try await client.send(.bookmarkList)
        } catch {
            return (
                CLIOutput(stderr: "Error: could not reach daemon — \(error.localizedDescription)\n"),
                .daemonError
            )
        }

        guard case .bookmarks(let bookmarks) = response else {
            return (CLIOutput(stderr: "Error: unexpected response from daemon\n"), .daemonError)
        }

        guard let bookmark = bookmarks.first(where: { $0.name == name }) else {
            return (
                CLIOutput(stderr: "Error: no bookmark named '\(name)'. List saved bookmarks with :bm in the REPL.\n"),
                .queryError
            )
        }

        // Run the bookmark's stored query as a normal single-shot search.
        return await SingleShot.execute(query: bookmark.query, options: options, client: client)
    }

    // MARK: - Subcommand Handlers

    /// Handle `daemon start|stop|restart|status` subcommand.
    private static func handleDaemonSubcommand(
        action: String?,
        clientProvider: (any IPCClientProtocol)?
    ) async -> (CLIOutput, CLIExitCode) {
        guard let action else {
            return (
                CLIOutput(stderr: "Usage: \(Product.command) daemon start|stop|restart|status\n"),
                .queryError
            )
        }

        guard let subcommand = DaemonSubcommand(rawValue: action) else {
            return (
                CLIOutput(stderr: "Unknown daemon action: \(action). Use start, stop, restart, or status.\n"),
                .queryError
            )
        }

        let client: any IPCClientProtocol
        if let provider = clientProvider {
            client = provider
        } else {
            let ipcClient = IPCClient(socketPath: Product.socketPath)
            do {
                try await ipcClient.ensureDaemonRunning()
            } catch {
                // For daemon start/restart, the daemon may not be running yet — that's OK.
                // For stop/status, we need it running but the runner handles the error.
                if subcommand != .start && subcommand != .restart {
                    return (
                        CLIOutput(stderr: "Error: could not reach daemon — \(error.localizedDescription)\n"),
                        .daemonError
                    )
                }
            }
            client = ipcClient
        }

        let runner = DaemonCommandRunner()
        let exitCode = await runner.run(subcommand, client: client)
        return (CLIOutput(), CLIExitCode(rawValue: exitCode) ?? .queryError)
    }

    /// Handle `config get|set|list|reset` subcommand.
    private static func handleConfigSubcommand(
        action: String?,
        extraArgs: [String],
        clientProvider: (any IPCClientProtocol)?
    ) async -> (CLIOutput, CLIExitCode) {
        guard let action else {
            return (
                CLIOutput(stderr: "Usage: \(Product.command) config get|set|list|reset\n"),
                .queryError
            )
        }

        let client: any IPCClientProtocol
        if let provider = clientProvider {
            client = provider
        } else {
            let ipcClient = IPCClient(socketPath: Product.socketPath)
            do {
                try await ipcClient.ensureDaemonRunning()
            } catch {
                return (
                    CLIOutput(stderr: "Error: could not start daemon — \(error.localizedDescription)\n"),
                    .daemonError
                )
            }
            client = ipcClient
        }

        // ConfigCommandRunner writes to a CLIOutputWriter.
        // Capture output into CLIOutput for return.
        let capturingOutput = CapturingOutputWriter()

        switch action {
        case "get":
            guard let key = extraArgs.first else {
                return (CLIOutput(stderr: "Usage: \(Product.command) config get <key>\n"), .queryError)
            }
            let code = await ConfigCommandRunner.get(key: key, client: client, output: capturingOutput)
            return (capturingOutput.toCLIOutput(), CLIExitCode(rawValue: code) ?? .queryError)

        case "set":
            guard extraArgs.count >= 2 else {
                return (CLIOutput(stderr: "Usage: \(Product.command) config set <key> <value>\n"), .queryError)
            }
            let code = await ConfigCommandRunner.set(
                key: extraArgs[0], value: extraArgs[1],
                client: client, output: capturingOutput
            )
            return (capturingOutput.toCLIOutput(), CLIExitCode(rawValue: code) ?? .queryError)

        case "list":
            let code = await ConfigCommandRunner.list(client: client, output: capturingOutput)
            return (capturingOutput.toCLIOutput(), CLIExitCode(rawValue: code) ?? .queryError)

        case "reset":
            let code = await ConfigCommandRunner.reset(client: client, output: capturingOutput)
            return (capturingOutput.toCLIOutput(), CLIExitCode(rawValue: code) ?? .queryError)

        default:
            return (
                CLIOutput(stderr: "Unknown config action: \(action). Use get, set, list, or reset.\n"),
                .queryError
            )
        }
    }

    /// Handle `install` subcommand.
    private static func handleInstallSubcommand() -> (CLIOutput, CLIExitCode) {
        let capturingOutput = CapturingOutputWriter()
        do {
            let code = try InstallCommandRunner.install(output: capturingOutput)
            return (capturingOutput.toCLIOutput(), CLIExitCode(rawValue: code) ?? .queryError)
        } catch {
            return (CLIOutput(stderr: "Error: \(error.localizedDescription)\n"), .queryError)
        }
    }

    /// Handle `uninstall` subcommand.
    private static func handleUninstallSubcommand() -> (CLIOutput, CLIExitCode) {
        let capturingOutput = CapturingOutputWriter()
        do {
            let code = try InstallCommandRunner.uninstall(output: capturingOutput)
            return (capturingOutput.toCLIOutput(), CLIExitCode(rawValue: code) ?? .queryError)
        } catch {
            return (CLIOutput(stderr: "Error: \(error.localizedDescription)\n"), .queryError)
        }
    }

    // MARK: - Helpers

    /// Extract positional arguments (non-flag) from the raw args list.
    /// Skips values consumed by flags (e.g. the "5" in "--limit 5").
    private static func extractPositionalArgs(from args: [String]) -> [String] {
        var positionals: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--") {
                // Skip the flag and its value (if it takes one)
                switch arg {
                case "--sort", "--limit", "--offset", "--port", "--bookmark":
                    i += 2 // skip flag + value
                default:
                    i += 1 // boolean flag
                }
            } else {
                positionals.append(arg)
                i += 1
            }
        }
        return positionals
    }
}

// MARK: - CapturingOutputWriter

/// Captures CLI output into buffers for returning as CLIOutput.
/// Used by subcommand handlers that write to CLIOutputWriter.
private final class CapturingOutputWriter: CLIOutputWriter, @unchecked Sendable {
    private var stdout = ""
    private var stderr = ""

    public func write(_ text: String) {
        stdout += text
    }

    public func writeError(_ text: String) {
        stderr += text
    }

    public func toCLIOutput() -> CLIOutput {
        CLIOutput(stdout: stdout, stderr: stderr)
    }
}

// MARK: - CLIOutput REPL hint

extension CLIOutput {
    /// Indicates this output is a REPL hint (not real output).
    /// The public `run(args:)` uses this to decide whether to launch REPL.
    var _replHint: Bool {
        stdout.contains("interactive REPL")
    }
}
