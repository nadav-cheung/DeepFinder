import Foundation

// MARK: - C readline/libedit function declarations
//
// Darwin ships libedit which provides readline-compatible functions.
// These are not exposed via a Swift module, so we declare them explicitly.

@_silgen_name("readline")
private func _readline(_ prompt: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("add_history")
private func _add_history(_ line: UnsafePointer<CChar>)
@_silgen_name("read_history")
private func _read_history(_ path: UnsafePointer<CChar>) -> CInt
@_silgen_name("write_history")
private func _write_history(_ path: UnsafePointer<CChar>) -> CInt
@_silgen_name("history_truncate_file")
private func _history_truncate_file(_ path: UnsafePointer<CChar>, _ n: CInt) -> CInt

// MARK: - REPLInputSource

/// Abstraction over the REPL input mechanism.
///
/// Production uses `StdinInputSource` (wraps libedit readline).
/// Tests inject mock implementations for deterministic behavior.
protocol REPLInputSource: Sendable {
    /// Read one line of input. Return `nil` to signal EOF (Ctrl+D).
    func readline(prompt: String) -> String?
}

// MARK: - REPLErrorOutput

/// Abstraction over REPL output (both stdout and stderr).
///
/// Production writes to real file descriptors.
/// Tests inject a capturing implementation for assertion.
protocol REPLErrorOutput: Sendable {
    func write(_ text: String)
    func writeError(_ text: String)
}

// MARK: - StdinOutput

/// Production output: writes to stdout and stderr.
struct StdinOutput: REPLErrorOutput {
    func write(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }

    func writeError(_ text: String) {
        fputs(text, stderr)
        fflush(stderr)
    }
}

// MARK: - StdinInputSource

/// Production input source wrapping libedit's readline.
struct StdinInputSource: REPLInputSource {
    func readline(prompt: String) -> String? {
        guard let cString = _readline(prompt) else {
            return nil  // EOF (Ctrl+D)
        }
        let line = String(cString: cString)
        free(cString)

        // Add to libedit history if non-empty
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            _add_history(trimmed)
        }

        return line
    }
}

// MARK: - REPL

/// Interactive read-eval-print loop for DeepFinder.
///
/// Reads user input via a `REPLInputSource`, dispatches search queries
/// and REPL commands, and writes output via `REPLErrorOutput`.
///
/// Designed for testability: inject `MockInputSource` and `REPLTestOutput`
/// in tests; production uses `StdinInputSource` and `StdinOutput`.
actor REPL {

    // MARK: - Properties

    private let client: any IPCClientProtocol
    private let inputSource: any REPLInputSource
    private let output: any REPLErrorOutput
    private let historyPath: String?

    /// Last search results, stored for `:open N` / `:reveal N` / `:explain N`.
    ///
    /// Updated on each query. 1-based indexing: result 1 corresponds to `lastResults[0]`.
    var lastResults: [SearchResult] = []

    /// Last search query string, stored for `:explain N`.
    var lastQuery: String = ""

    /// Operation history for `:undo` support.
    let operationHistory: NLOperationHistory = NLOperationHistory()

    // MARK: - Init

    /// Create a REPL instance.
    ///
    /// - Parameters:
    ///   - client: IPC client for daemon communication.
    ///   - inputSource: Source of user input (readline abstraction).
    ///   - output: Output destination for results and messages.
    ///   - historyPath: Path for readline history persistence. `nil` disables persistence.
    init(
        client: any IPCClientProtocol,
        inputSource: any REPLInputSource = StdinInputSource(),
        output: any REPLErrorOutput = StdinOutput(),
        historyPath: String? = Product.historyPath
    ) {
        self.client = client
        self.inputSource = inputSource
        self.output = output
        self.historyPath = historyPath
    }

    // MARK: - Main Loop

    /// Run the REPL loop. Blocks until `:quit` or EOF.
    func run() async {
        // Print welcome banner
        output.write("\(Product.name) \(Product.version) — type :help for commands\n")

        // Load readline history if path provided
        if let historyPath {
            let expanded = NSString(string: historyPath).expandingTildeInPath
            _ = _read_history(expanded)
        }

        defer {
            // Save readline history on exit
            if let historyPath {
                let expanded = NSString(string: historyPath).expandingTildeInPath
                // Ensure directory exists
                let dir = (expanded as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true
                )
                _ = _write_history(expanded)
                // Limit to 1000 entries
                _ = _history_truncate_file(expanded, 1000)
            }
            output.write("Goodbye.\n")
        }

        // Main loop
        while true {
            guard let rawLine = inputSource.readline(prompt: "> ") else {
                // EOF (Ctrl+D)
                break
            }

            let shouldContinue = await handleInput(rawLine)
            if !shouldContinue {
                break
            }
        }
    }

    // MARK: - Input Handling

    /// Process one line of input. Returns `false` to quit.
    private func handleInput(_ input: String) async -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true  // Ignore empty input
        }

        let (command, args, isQuery) = REPLCommand.parse(trimmed)

        if isQuery {
            await executeQuery(trimmed)
            return true
        }

        if let command {
            return await dispatchCommand(command, args: args)
        }

        // Unknown :command
        output.writeError("Unknown command. Type :help for available commands.\n")
        return true
    }

    // MARK: - Query Execution

    /// Send a search query to the daemon and display results.
    private func executeQuery(_ query: String) async {
        lastQuery = query
        let request = IPCRequest.query(query, limit: nil)
        let response: IPCResponse
        do {
            response = try await client.send(request)
        } catch {
            output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            return
        }

        switch response {
        case .results(let results, _):
            lastResults = results
            if results.isEmpty {
                output.write("No results found.\n")
            } else {
                let options = CLIOptions(query: query)
                let formatted = TerminalFormatter.format(results, options: options, isTerminal: true)
                output.write(formatted + "\n")
                output.write("\(results.count) result\(results.count == 1 ? "" : "s")\n")
            }

        case .error(let ipcError):
            switch ipcError {
            case .queryError(let message):
                output.writeError("Error: \(message)\n")
            case .daemonNotReady:
                output.writeError("Error: daemon not ready\n")
            case .invalidRequest(let message):
                output.writeError("Error: \(message)\n")
            case .permissionDenied(let message):
                output.writeError("Error: \(message)\n")
            }

        default:
            output.writeError("Error: unexpected response from daemon\n")
        }
    }

    // MARK: - Command Dispatch

    /// Handle a REPL command. Returns `false` to quit.
    private func dispatchCommand(_ command: REPLCommand, args: [String]) async -> Bool {
        switch command {
        case .help:
            return handleHelp()
        case .quit:
            return false
        case .stats:
            return await handleStats()
        case .config:
            return await handleConfig(args: args)
        case .open:
            return handleOpen(args: args)
        case .reveal:
            return handleReveal(args: args)
        case .daemon:
            return await handleDaemon()
        case .explain:
            return handleExplain(args: args)
        case .dataPreview:
            return handleDataPreview()
        case .undo:
            return await handleUndo()
        }
    }

    // MARK: - Command Handlers

    /// Display help text listing all available REPL commands.
    private func handleHelp() -> Bool {
        let lines = ["Commands:"]
        let entries = REPLCommand.allCases.map { cmd in
            let aliases = aliasList(for: cmd)
            let aliasStr = aliases.isEmpty ? "" : " (\(aliases.joined(separator: ", ")))"
            // Pad command name to 12 chars for columnar alignment
            let padded = ":\(cmd.rawValue)\(aliasStr)".padding(toLength: 14, withPad: " ", startingAt: 0)
            return "  \(padded)\(cmd.description)"
        }
        output.write((lines + entries).joined(separator: "\n") + "\n")
        return true
    }

    /// Returns alias strings for a given command (e.g. `:q` for `:quit`).
    private func aliasList(for command: REPLCommand) -> [String] {
        switch command {
        case .quit: return [":q"]
        case .help: return [":h"]
        default: return []
        }
    }

    /// Fetch and display daemon statistics (file count, index state, uptime, memory).
    private func handleStats() async -> Bool {
        let response: IPCResponse
        do {
            response = try await client.send(.stats)
        } catch {
            output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            return true
        }

        switch response {
        case .stats(let stats):
            output.write("Files indexed: \(stats.totalFiles)\n")
            output.write("Index state: \(stats.indexState)\n")
            output.write("Daemon uptime: \(String(format: "%.0f", stats.uptimeSeconds))s\n")
            output.write("Memory: \(String(format: "%.1f", stats.memoryUsageMB)) MB\n")
        case .error(let ipcError):
            output.writeError("Error: \(ipcError)\n")
        default:
            output.writeError("Error: unexpected response\n")
        }
        return true
    }

    /// Handle `:config KEY [VALUE]` — get or set a configuration key.
    private func handleConfig(args: [String]) async -> Bool {
        guard let key = args.first else {
            output.writeError("Usage: :config KEY [VALUE]\n")
            return true
        }

        let request: IPCRequest
        if args.count >= 2 {
            request = .configSet(key: key, value: args[1])
        } else {
            request = .configGet(key: key)
        }

        let response: IPCResponse
        do {
            response = try await client.send(request)
        } catch {
            output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            return true
        }

        switch response {
        case .ack:
            output.write("OK\n")
        case .error(let ipcError):
            output.writeError("Error: \(ipcError)\n")
        default:
            output.writeError("Error: unexpected response\n")
        }
        return true
    }

    /// Handle `:open N` — open result N with the default application.
    private func handleOpen(args: [String]) -> Bool {
        guard let indexStr = args.first, let index = Int(indexStr) else {
            output.writeError("Usage: :open N (N is a 1-based result index)\n")
            return true
        }

        guard index >= 1 && index <= lastResults.count else {
            output.writeError("Invalid index: \(index). Last search had \(lastResults.count) result(s).\n")
            return true
        }

        let result = lastResults[index - 1]
        openFile(at: result.record.path)
        output.write("Opened: \(result.record.path)\n")
        return true
    }

    /// Handle `:reveal N` — reveal result N in Finder.
    private func handleReveal(args: [String]) -> Bool {
        guard let indexStr = args.first, let index = Int(indexStr) else {
            output.writeError("Usage: :reveal N (N is a 1-based result index)\n")
            return true
        }

        guard index >= 1 && index <= lastResults.count else {
            output.writeError("Invalid index: \(index). Last search had \(lastResults.count) result(s).\n")
            return true
        }

        let result = lastResults[index - 1]
        revealFile(at: result.record.path)
        output.write("Revealed: \(result.record.path)\n")
        return true
    }

    /// Open a file with the default application via `/usr/bin/open`.
    private func openFile(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        try? process.run()
    }

    /// Reveal a file in Finder via `/usr/bin/open -R`.
    private func revealFile(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-R", path]
        try? process.run()
    }

    private func handleDaemon() async -> Bool {
        let response: IPCResponse
        do {
            response = try await client.send(.indexStatus)
        } catch {
            output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            return true
        }

        switch response {
        case .indexStatus(let status):
            output.write("Index state: \(status.state)\n")
            output.write("Files indexed: \(status.filesIndexed)\n")
            if let lastScan = status.lastScanDate {
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .short
                output.write("Last scan: \(df.string(from: lastScan))\n")
            }
        case .error(let ipcError):
            output.writeError("Error: \(ipcError)\n")
        default:
            output.writeError("Error: unexpected response\n")
        }
        return true
    }

    /// Handle `:explain N` — show match explanation for result N.
    private func handleExplain(args: [String]) -> Bool {
        guard let indexStr = args.first, let index = Int(indexStr) else {
            output.writeError("Usage: :explain N (N is a 1-based result index)\n")
            return true
        }

        guard index >= 1 && index <= lastResults.count else {
            output.writeError("Invalid index: \(index). Last search had \(lastResults.count) result(s).\n")
            return true
        }

        let result = lastResults[index - 1]
        let explanation = MatchExplainer.explain(
            result: result,
            query: lastQuery,
            filters: []
        )

        output.write("Match type: \(explanation.matchType)\n")
        if let position = explanation.position {
            output.write("Position: \(position)\n")
        }
        output.write("Reason: \(explanation.reason)\n")
        return true
    }

    /// Handle `:data_preview` — show what data gets sent to AI providers.
    private func handleDataPreview() -> Bool {
        let preview = AIConfig.dataPreview()
        output.write(preview + "\n")
        return true
    }

    /// Handle `:undo` — undo last file operation.
    private func handleUndo() async -> Bool {
        guard let record = await operationHistory.popLast() else {
            output.write("Nothing to undo.\n")
            return true
        }
        let op = record.operation
        output.write("Undone: \(op.type.rawValue) '\(op.sourcePattern)' to '\(op.destination)'\n")
        return true
    }
}
