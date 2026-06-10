import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderServices

// MARK: - SingleShot

/// Executes a single search query via the daemon IPC.
///
/// Handles the request/response cycle for one-shot mode
/// (`deepfinder "query"`). Applies limit from CLI options
/// to the IPC request, and delegates formatting to `TerminalFormatter`.
///
/// Error messages are returned in `CLIOutput.stderr` so the caller
/// can route them correctly (terminal stderr, not stdout).
public struct SingleShot {

    /// Execute a single query against the daemon.
    ///
    /// - Parameters:
    ///   - query: The search query string.
    ///   - options: Parsed CLI options (limit, sort, output format, etc.).
    ///   - client: IPC client to communicate with the daemon.
    /// - Returns: Tuple of (collected output with stdout/stderr separation, exit code).
    public static func execute(
        query: String,
        options: CLIOptions,
        client: any IPCClientProtocol
    ) async -> (output: CLIOutput, exitCode: CLIExitCode) {
        // Build and send the IPC request
        let request: IPCRequest = .query(query, limit: options.limit)
        let response: IPCResponse
        do {
            response = try await client.send(request)
        } catch let error as IPCClientError {
            return (CLIOutput(stderr: "Error: could not reach daemon — \(error.description)\n"), .daemonError)
        } catch {
            return (CLIOutput(stderr: "Error: could not reach daemon — \(error.localizedDescription)\n"), .daemonError)
        }

        // Process response
        switch response {
        case .results(let results, _):
            if results.isEmpty {
                // Try fuzzy suggestions (REQ-1.0-03)
                var suggestion: String?
                if let suggestResponse = try? await client.send(.suggest(query: query)),
                   case .suggestions(let terms) = suggestResponse, !terms.isEmpty {
                    suggestion = "Did you mean: \(terms.joined(separator: ", "))?\n"
                }
                return (CLIOutput(stderr: suggestion ?? ""), .noResults)
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

            // TerminalFormatter handles output mode selection (JSON, NUL, ANSI)
            let formatted = TerminalFormatter.format(finalResults, options: options)
            return (CLIOutput(stdout: formatted), .success)

        case .error(let ipcError):
            switch ipcError {
            case .queryError(let message):
                return (CLIOutput(stderr: "Error: \(message)\n"), .queryError)
            case .daemonNotReady:
                return (CLIOutput(stderr: "Error: daemon not ready\n"), .daemonError)
            case .invalidRequest(let message):
                return (CLIOutput(stderr: "Error: \(message)\n"), .queryError)
            case .permissionDenied(let message):
                return (CLIOutput(stderr: "Error: \(message)\n"), .queryError)
            case .incompatibleProtocolVersion:
                return (CLIOutput(stderr: "Error: Protocol version mismatch — your client is newer than the daemon. Please update the daemon.\n"), .daemonError)
            }

        default:
            return (CLIOutput(stderr: "Error: unexpected response from daemon\n"), .daemonError)
        }
    }
}
