import Foundation

// MARK: - SingleShot

/// Executes a single search query via the daemon IPC.
///
/// Handles the request/response cycle for one-shot mode
/// (`deepfinder "query"`). Applies limit from CLI options
/// to the IPC request, and delegates formatting to `TerminalFormatter`.
struct SingleShot {

    /// Execute a single query against the daemon.
    ///
    /// - Parameters:
    ///   - query: The search query string.
    ///   - options: Parsed CLI options (limit, sort, output format, etc.).
    ///   - client: IPC client to communicate with the daemon.
    /// - Returns: Tuple of (formatted output string, exit code).
    static func execute(
        query: String,
        options: CLIOptions,
        client: any IPCClientProtocol
    ) async -> (output: String, exitCode: CLIExitCode) {
        // Build and send the IPC request
        let request: IPCRequest = .query(query, limit: options.limit)
        let response: IPCResponse
        do {
            response = try await client.send(request)
        } catch is IPCClientError {
            return ("", .daemonError)
        } catch {
            return ("", .daemonError)
        }

        // Process response
        switch response {
        case .results(let results, _):
            if results.isEmpty {
                return ("", .noResults)
            }

            // Apply client-side sort if requested
            let sortedResults: [SearchResult]
            if let sortOption = options.sort {
                let criterion: SortCriterion = switch sortOption {
                case .name: .name
                case .size: .size
                case .date: .date
                }
                var sorted = SearchSorter.sort(results, by: criterion)
                if options.reverse {
                    sorted = sorted.reversed()
                }
                sortedResults = sorted
            } else {
                sortedResults = results
            }

            // Apply client-side offset
            var finalResults = sortedResults
            if let offset = options.offset, offset < finalResults.count {
                finalResults = Array(finalResults.dropFirst(offset))
            } else if let offset = options.offset, offset >= finalResults.count {
                finalResults = []
            }

            // Apply client-side limit (additional to server-side limit)
            // If server already limited, this only further reduces
            // If server returned all, this applies the user's limit
            // TerminalFormatter handles output mode selection

            let output = TerminalFormatter.format(finalResults, options: options)
            return (output, .success)

        case .error(let ipcError):
            switch ipcError {
            case .queryError(let message):
                return ("Error: \(message)\n", .queryError)
            case .daemonNotReady:
                return ("Error: daemon not ready\n", .daemonError)
            case .invalidRequest(let message):
                return ("Error: \(message)\n", .queryError)
            case .permissionDenied(let message):
                return ("Error: \(message)\n", .queryError)
            }

        default:
            return ("Error: unexpected response from daemon\n", .daemonError)
        }
    }
}
