// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderServices

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

// MARK: - libedit completion C interop

/// Opaque pointer type for libedit's completion matches list.
/// We only need to pass this to rl_completion_matches; the actual type is `char**`.
public typealias CompletionMatches = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>

/// libedit's rl_completion_matches function (analogous to GNU readline's).
/// Takes a text prefix and a generator function, returns a malloc'd array of matches.
@_silgen_name("rl_completion_matches")
private func _rl_completion_matches(
    _ text: UnsafePointer<CChar>,
    _ generator: @convention(c) (UnsafePointer<CChar>, CInt) -> UnsafeMutablePointer<CChar>?
) -> CompletionMatches?

/// The C-callable completion entry generator function.
///
/// libedit calls this repeatedly with incrementing `state` (0 = first call,
/// non-zero = subsequent) to iterate through matches. Returns NULL when done.
/// This is a C function pointer — it cannot capture any Swift context.
/// It reads from `CompletionContext` (static bridge) instead.

// File-scope static state for the completion generator (safe: readline is single-threaded).
nonisolated(unsafe) private var _completionMatches: [String] = []
nonisolated(unsafe) private var _completionMatchIndex: Int = 0

private func _completionEntryGenerator(_ text: UnsafePointer<CChar>, _ state: CInt) -> UnsafeMutablePointer<CChar>? {
    if state == 0 {
        // First call: compute all matches
        let textStr = String(cString: text)
        _completionMatches = CompletionContext.complete(textStr)
        _completionMatchIndex = 0
    }

    guard _completionMatchIndex < _completionMatches.count else {
        return nil
    }

    defer { _completionMatchIndex += 1 }
    return strdup(_completionMatches[_completionMatchIndex])
}

/// The C-callable attempted completion function.
///
/// Called by libedit when the user presses Tab. Returns a malloc'd array
/// of matches, or NULL to fall back to default filename completion.
private func _attemptedCompletion(_ text: UnsafePointer<CChar>, _ start: CInt, _ end: CInt) -> CompletionMatches? {
    let textStr = String(cString: text)

    // Get completions from the engine
    let completions = CompletionContext.complete(textStr)

    guard !completions.isEmpty else {
        return nil  // No matches — let libedit fall back to default (filename) completion
    }

    // Multiple matches — let libedit iterate via the entry generator
    return _rl_completion_matches(text, _completionEntryGenerator)
}

/// Set libedit's rl_attempted_completion_function to our completion handler.
///
/// Accesses the C global via dlsym because Swift 6 strict concurrency
/// does not allow mutable @_silgen_name global variables.
private func _installReadlineCompletion() {
    // rl_attempted_completion_function
    if let sym = dlsym(dlopen(nil, RTLD_NOW), "rl_attempted_completion_function") {
        let ptr = sym.assumingMemoryBound(to: (@convention(c) (UnsafePointer<CChar>, CInt, CInt) -> CompletionMatches?)?.self)
        ptr.pointee = _attemptedCompletion
    }
    // rl_completion_append_character
    if let sym = dlsym(dlopen(nil, RTLD_NOW), "rl_completion_append_character") {
        let ptr = sym.assumingMemoryBound(to: CInt.self)
        ptr.pointee = CInt(Character(" ").asciiValue!)
    }
}

// MARK: - REPLInputSource

/// Abstraction over the REPL input mechanism.
///
/// Production uses `StdinInputSource` (wraps libedit readline).
/// Tests inject mock implementations for deterministic behavior.
public protocol REPLInputSource: Sendable {
    /// Read one line of input. Return `nil` to signal EOF (Ctrl+D).
    func readline(prompt: String) -> String?
}


// MARK: - StdinInputSource

/// Production input source wrapping libedit's readline.
public struct StdinInputSource: REPLInputSource {
    public init() {}

    /// Whether tab-completion has been installed via rl_attempted_completion_function.
    nonisolated(unsafe) private static var completionInstalled = false

    /// Install tab-completion callback (once per process).
    public static func installCompletion() {
        guard !completionInstalled else { return }
        _installReadlineCompletion()
        completionInstalled = true
    }

    public func readline(prompt: String) -> String? {
        Self.installCompletion()

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

// MARK: - CompletionEngine

/// Synchronous tab-completion engine for the REPL.
///
/// Provides completions for:
/// - REPL commands (e.g. `:he` → `:help`)
/// - Filter keywords (e.g. `ex` → `ext:`)
/// - Result indices for `:open`/`:reveal`
/// - Filenames from last search results
///
/// Designed to be synchronous because libedit's completion callback
/// is a C function pointer that cannot call async code.
public struct CompletionEngine: Sendable {

    /// REPL commands with leading colon, kept in sync with REPLCommand.allCases.
    private static let commands: [String] = [
        ":help", ":quit", ":stats", ":config", ":daemon",
        ":open", ":reveal", ":explain", ":dataPreview", ":undo",
    ]

    /// Search filter keyword prefixes.
    private static let filterKeywords: [String] = [
        "ext:", "size:", "type:", "dm:", "dc:", "path:",
        "file:", "folder:", "depth:", "case:", "regex:",
        "len:", "width:", "height:", "duration:", "pages:",
        "pagecount:", "fps:", "bitrate:", "artist:", "album:",
        "title:", "genre:", "codec:", "audio:", "video:", "pic:", "doc:",
    ]

    /// Last search results for :open/:reveal index completion and filename completion.
    public let lastResults: [SearchResult]

    /// Create a completion engine with the given last search results.
    public init(lastResults: [SearchResult]) {
        self.lastResults = lastResults
    }

    /// Return completions for the given input text.
    ///
    /// - Parameter text: The current input line (what the user has typed so far).
    /// - Returns: An array of completion strings that could replace the current token.
    public func complete(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // 1. Command completion: input starts with ":"
        if trimmed.hasPrefix(":") {
            // Check for :open or :reveal with a trailing space — complete with indices
            let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if let firstToken = tokens.first {
                let cmdLower = firstToken.lowercased()
                // Use original text (not trimmed) to detect trailing space
                let hasSpace = text.hasSuffix(" ") || tokens.count > 1

                if (cmdLower == ":open" || cmdLower == ":reveal") && hasSpace {
                    return completeResultIndices()
                }
            }

            return completeCommands(prefix: trimmed)
        }

        // 2. Filter keyword + filename completion for plain text
        return completeFiltersAndFilenames(prefix: trimmed)
    }

    // MARK: - Private

    /// Complete REPL commands matching the given prefix.
    private func completeCommands(prefix: String) -> [String] {
        let lowered = prefix.lowercased()
        return Self.commands.filter { $0.lowercased().hasPrefix(lowered) }
    }

    /// Complete result indices (for :open/:reveal).
    private func completeResultIndices() -> [String] {
        guard !lastResults.isEmpty else { return [] }
        return lastResults.enumerated().map { index, result in
            "\(index + 1)  \(result.record.name)"
        }
    }

    /// Complete filter keywords and filenames matching the given prefix.
    private func completeFiltersAndFilenames(prefix: String) -> [String] {
        var completions: [String] = []

        // Filter keyword completions
        let lowered = prefix.lowercased()
        for keyword in Self.filterKeywords {
            if keyword.hasPrefix(lowered) || keyword.lowercased().hasPrefix(lowered) {
                completions.append(keyword)
            }
        }

        // Filename completions from last results
        if !lowered.isEmpty {
            for result in lastResults {
                if result.record.name.lowercased().hasPrefix(lowered) {
                    if !completions.contains(result.record.name) {
                        completions.append(result.record.name)
                    }
                }
            }
        }

        return completions
    }
}

// MARK: - CompletionContext (static bridge for C callback)

/// Static bridge holding the current completion state.
///
/// libedit's completion callback is a C function pointer that cannot
/// capture Swift context. This static class provides the bridge between
/// the REPL actor and the C callback.
public enum CompletionContext: Sendable {

    /// Current completion engine state (updated by REPL before readline).
    nonisolated(unsafe) private static var _engine: CompletionEngine = CompletionEngine(lastResults: [])

    /// Update the completion context with current REPL state.
    public static func update(lastResults: [SearchResult]) {
        _engine = CompletionEngine(lastResults: lastResults)
    }

    /// Get completions for the current input via the stored engine.
    public static func complete(_ text: String) -> [String] {
        _engine.complete(text)
    }
}

// MARK: - REPL

/// Interactive read-eval-print loop for DeepFinder.
///
/// Reads user input via a `REPLInputSource`, dispatches search queries
/// and REPL commands, and writes output via `CLIOutputWriter`.
///
/// Designed for testability: inject `MockInputSource` and a capturing output
/// in tests; production uses `StdinInputSource` and `StdoutWriter`.
public actor REPL {

    // MARK: - Properties

    private let client: any IPCClientProtocol
    private let inputSource: any REPLInputSource
    private let output: any CLIOutputWriter
    private let historyPath: String?

    /// Last search results, stored for `:open N` / `:reveal N` / `:explain N`.
    ///
    /// Updated on each query. 1-based indexing: result 1 corresponds to `lastResults[0]`.
    public var lastResults: [SearchResult] = []

    /// Last search query string, stored for `:explain N`.
    public var lastQuery: String = ""

    /// Last listed bookmarks, for `:bm delete N` (1-based).
    private var lastBookmarks: [SearchBookmark] = []

    /// Operation history for `:undo` support.
    public let operationHistory: NLOperationHistory = NLOperationHistory()

    // MARK: - Init

    /// Create a REPL instance.
    ///
    /// - Parameters:
    ///   - client: IPC client for daemon communication.
    ///   - inputSource: Source of user input (readline abstraction).
    ///   - output: Output destination for results and messages.
    ///   - historyPath: Path for readline history persistence. `nil` disables persistence.
    public init(
        client: any IPCClientProtocol,
        inputSource: any REPLInputSource = StdinInputSource(),
        output: any CLIOutputWriter = StdoutWriter(),
        historyPath: String? = Product.historyPath
    ) {
        self.client = client
        self.inputSource = inputSource
        self.output = output
        self.historyPath = historyPath
    }

    // MARK: - Main Loop

    /// Run the REPL loop. Blocks until `:quit` or EOF.
    public func run() async {
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
            // Update completion context with current state before readline
            CompletionContext.update(lastResults: lastResults)

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
            showSuggestions()  // REQ-1.3-07: empty input shows recent searches + syntax tips
            return true
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

    // MARK: - Suggestions (REQ-1.3-07)

    /// Display recent searches and syntax tips on empty input.
    private func showSuggestions() {
        // Recent searches from this session
        let recent = recentQueries.suffix(5)
        if !recent.isEmpty {
            output.write("\u{001B}[1mRecent searches:\u{001B}[0m\n")
            for (i, query) in recent.enumerated() {
                output.write("  \(i + 1). \(query)\n")
            }
            output.write("\n")
        }

        // Syntax tips
        output.write("\u{001B}[2mTips:\u{001B}[0m\n")
        output.write("  \u{001B}[2mext:pdf size:>1mb   — filter by extension and size\n")
        output.write("  \"exact phrase\"        — phrase search\n")
        output.write("  path:~/Documents       — search in path\n")
        output.write("  dupe: | sizedupe:      — find duplicates\n")
        output.write("  :help                  — all commands\u{001B}[0m\n")
    }

    /// Recent queries from the current session (for suggestions).
    private var recentQueries: [String] = []

    // MARK: - Query Execution

    /// Send a search query to the daemon and display results.
    private func executeQuery(_ query: String) async {
        lastQuery = query
        recentQueries.append(query)

        // Duplicate-finder commands (dupe:/sizedupe:/hashdupe:/empty:) route to
        // the duplicate finder rather than substring search.
        if let strategy = DuplicateCommand.detect(query) {
            await executeDuplicate(strategy: strategy)
            return
        }

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
            case .incompatibleProtocolVersion:
                output.writeError("Error: Protocol version mismatch — your client is newer than the daemon. Please update the daemon.\n")
            }

        default:
            output.writeError("Error: unexpected response from daemon\n")
        }
    }

    /// Execute a duplicate-finder query and display grouped results.
    private func executeDuplicate(strategy: DuplicateQueryStrategy) async {
        let response: IPCResponse
        do {
            response = try await client.send(.duplicateQuery(strategy: strategy))
        } catch {
            output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            return
        }

        switch response {
        case .duplicates(let groups):
            let total = groups.reduce(0) { $0 + $1.records.count }
            if total == 0 {
                let label = strategy == .empty ? "No empty files found" : "No duplicates found"
                output.write("\(label)\n")
            } else {
                let options = CLIOptions(query: lastQuery)
                let formatted = TerminalFormatter.formatDuplicates(groups, strategy: strategy, options: options)
                output.write(formatted + "\n")
                output.write("\(total) file\(total == 1 ? "" : "s") across \(groups.count) group\(groups.count == 1 ? "" : "s")\n")
            }
        case .error(let ipcError):
            output.writeError("Error: \(ipcError)\n")
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
        case .bookmark:
            return await handleBookmark(args: args)
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
        do { try process.run() }
        catch { output.writeError("Error: failed to launch open command — \(error.localizedDescription)\n") }
    }

    /// Reveal a file in Finder via `/usr/bin/open -R`.
    private func revealFile(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-R", path]
        do { try process.run() }
        catch { output.writeError("Error: failed to launch open command — \(error.localizedDescription)\n") }
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

    // MARK: - Bookmarks (:bm)

    /// Handle `:bm` — list, `:bm save NAME`, or `:bm delete N`.
    private func handleBookmark(args: [String]) async -> Bool {
        let sub = args.first?.lowercased() ?? "list"

        switch sub {
        case "list", "":
            let response: IPCResponse
            do {
                response = try await client.send(.bookmarkList)
            } catch {
                output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
                return true
            }
            guard case .bookmarks(let bookmarks) = response else {
                output.writeError("Error: unexpected response from daemon\n")
                return true
            }
            lastBookmarks = bookmarks
            if bookmarks.isEmpty {
                output.write("No bookmarks saved. Use :bm save NAME after a search.\n")
            } else {
                for (i, bookmark) in bookmarks.enumerated() {
                    output.write("\(i + 1). \(bookmark.name) — \(bookmark.query)\n")
                }
            }

        case "save":
            guard let name = args.dropFirst().first, !name.isEmpty else {
                output.writeError("Usage: :bm save NAME\n")
                return true
            }
            guard !lastQuery.isEmpty else {
                output.writeError("No query to bookmark — run a search first.\n")
                return true
            }
            let bookmark = SearchBookmark(name: name, query: lastQuery)
            do {
                let response = try await client.send(.bookmarkSave(bookmark))
                if case .ack = response {
                    output.write("Saved: \(name) — \(lastQuery)\n")
                } else if case .error(let ipcError) = response {
                    output.writeError("Error: \(ipcError)\n")
                } else {
                    output.writeError("Error: could not save bookmark\n")
                }
            } catch {
                output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            }

        case "delete":
            guard let target = args.dropFirst().first,
                  let index = Int(target),
                  index >= 1, index <= lastBookmarks.count else {
                output.writeError("Usage: :bm delete N (list bookmarks first with :bm)\n")
                return true
            }
            let bookmark = lastBookmarks[index - 1]
            do {
                let response = try await client.send(.bookmarkDelete(bookmark.id))
                if case .ack = response {
                    output.write("Deleted: \(bookmark.name)\n")
                    lastBookmarks.remove(at: index - 1)
                } else if case .error(let ipcError) = response {
                    output.writeError("Error: \(ipcError)\n")
                } else {
                    output.writeError("Error: could not delete bookmark\n")
                }
            } catch {
                output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            }

        default:
            output.writeError("Usage: :bm [save NAME | delete N]\n")
        }
        return true
    }
}
