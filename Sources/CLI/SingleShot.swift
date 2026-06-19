// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

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
        // Duplicate-finder commands (dupe:/sizedupe:/hashdupe:/empty:) route to
        // the duplicate finder rather than substring search.
        if let strategy = DuplicateCommand.detect(query) {
            return await executeDuplicate(strategy: strategy, options: options, client: client)
        }

        // Build and send the IPC request
        // B4: pass offset to daemon so it applies offset server-side before
        // limit truncation — client-side dropFirst was broken for offset >= limit.
        let request: IPCRequest = .query(query, limit: options.limit, offset: options.offset)
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

            // Offset is applied server-side by the daemon (B4 fix).
            let finalResults = sortedResults

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

    /// Execute a duplicate-finder query (`dupe:`/`sizedupe:`/`hashdupe:`/`empty:`).
    private static func executeDuplicate(
        strategy: DuplicateQueryStrategy,
        options: CLIOptions,
        client: any IPCClientProtocol
    ) async -> (output: CLIOutput, exitCode: CLIExitCode) {
        let response: IPCResponse
        do {
            response = try await client.send(.duplicateQuery(strategy: strategy))
        } catch let error as IPCClientError {
            return (CLIOutput(stderr: "Error: could not reach daemon — \(error.description)\n"), .daemonError)
        } catch {
            return (CLIOutput(stderr: "Error: could not reach daemon — \(error.localizedDescription)\n"), .daemonError)
        }

        switch response {
        case .duplicates(let groups):
            let total = groups.reduce(0) { $0 + $1.records.count }
            if total == 0 {
                let label = strategy == .empty ? "No empty files found" : "No duplicates found"
                return (CLIOutput(stderr: "\(label)\n"), .noResults)
            }
            let formatted = TerminalFormatter.formatDuplicates(groups, strategy: strategy, options: options)
            return (CLIOutput(stdout: formatted), .success)
        case .error(let ipcError):
            return (CLIOutput(stderr: "Error: \(ipcError)\n"), .queryError)
        default:
            return (CLIOutput(stderr: "Error: unexpected response from daemon\n"), .daemonError)
        }
    }
}
