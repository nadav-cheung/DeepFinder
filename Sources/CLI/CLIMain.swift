import Foundation

// MARK: - CLIExitCode

/// Exit codes for the DeepFinder CLI.
///
/// These match the documented exit codes in `--help`:
/// - 0 = success
/// - 1 = no results found
/// - 2 = daemon error
/// - 3 = query error
enum CLIExitCode: Int32, Sendable, Equatable {
    case success = 0
    case noResults = 1
    case daemonError = 2
    case queryError = 3
}

// MARK: - CLIOutput

/// Output from a CLI run, separated into stdout and stderr streams.
struct CLIOutput: Sendable {
    var stdout: String = ""
    var stderr: String = ""
}

// MARK: - CLIMain

/// Top-level entry point for the DeepFinder CLI.
///
/// Parses arguments, handles meta-flags (--help, --version),
/// dispatches to REPL (v0.6) or single-shot query mode,
/// and returns the appropriate exit code along with collected output.
///
/// This struct performs no I/O — it returns all output as strings.
/// The caller (the `@main` entry point) is responsible for writing
/// to the actual stdout/stderr file descriptors.
struct CLIMain {

    /// Run the CLI with the given argument list.
    ///
    /// - Parameters:
    ///   - args: Command-line arguments excluding the program name
    ///     (i.e. `CommandLine.arguments.dropFirst()`).
    ///   - clientProvider: IPC client to use. Defaults to a real `IPCClient`.
    ///     Inject a `MockIPCClient` in tests to avoid needing a live daemon.
    /// - Returns: Tuple of (collected output, exit code).
    static func run(
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
            return (CLIOutput(stdout: "\(Product.name) \(Product.version)"), .success)
        }

        // 4. Handle --serve mode
        if options.serveMode {
            return await ServeMode.run(options: options, clientProvider: clientProvider)
        }

        // 5. Handle no query (v0.6 REPL placeholder)
        guard let query = options.query else {
            let msg = """
            Interactive REPL mode is coming in v0.6.
            For now, use: \(Product.command) "your query"
            """
            return (CLIOutput(stdout: msg), .success)
        }

        // 6. Create IPC client
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

        // 7. Execute single-shot query
        let (resultOutput, exitCode) = await SingleShot.execute(
            query: query,
            options: options,
            client: client
        )

        return (CLIOutput(stdout: resultOutput), exitCode)
    }
}
