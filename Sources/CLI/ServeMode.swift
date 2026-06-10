import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderServices

// MARK: - ServeMode

/// Handles `deepfinder --serve` mode: starts the HTTP search service.
///
/// Ensures the daemon is running, then starts an `HTTPSearchService`
/// on the specified port. In production, the caller blocks on the
/// returned signal until Ctrl+C.
public struct ServeMode {

    // MARK: - Run

    /// Execute serve mode: start daemon + HTTP service.
    ///
    /// - Parameters:
    ///   - options: Parsed CLI options (must have `serveMode == true`).
    ///   - clientProvider: Optional IPC client for testing.
    /// - Returns: Tuple of (collected output, exit code).
    public static func run(
        options: CLIOptions,
        clientProvider: (any IPCClientProtocol)? = nil
    ) async -> (output: CLIOutput, exitCode: CLIExitCode) {
        let port = UInt16(clamping: options.port)

        // 1. Ensure daemon is running
        let client: any IPCClientProtocol
        if let provider = clientProvider {
            // Test mode: verify the mock client works via a stats request
            client = provider
            do {
                _ = try await client.send(.stats)
            } catch {
                return (
                    CLIOutput(
                        stdout: "HTTP search service running on http://localhost:\(port)\n",
                        stderr: "Warning: daemon not available — search requests will fail\n"
                    ),
                    .success
                )
            }
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

        // 2. Build handlers that route through IPC
        let searchHandler: HTTPSearchService.SearchHandler = { query, limit, offset in
            do {
                let response = try await client.send(.query(query, limit: limit))
                switch response {
                case .results(let results, _):
                    return results.map { result in
                        [
                            "path": result.record.path,
                            "name": result.record.originalName,
                        ]
                    }
                default:
                    return []
                }
            } catch {
                return [["error": "daemon unavailable - \(error.localizedDescription)"]]
            }
        }

        let statsHandler: HTTPSearchService.StatsHandler = {
            do {
                let response = try await client.send(.stats)
                switch response {
                case .stats(let stats):
                    return [
                        "totalFiles": stats.totalFiles,
                        "indexState": stats.indexState,
                        "uptimeSeconds": stats.uptimeSeconds,
                        "memoryUsageMB": stats.memoryUsageMB,
                    ]
                default:
                    return [:]
                }
            } catch {
                return [:]
            }
        }

        // 3. Start HTTP service
        let service = HTTPSearchService(
            port: port,
            searchHandler: searchHandler,
            statsHandler: statsHandler
        )

        do {
            try await service.start()
        } catch {
            return (
                CLIOutput(stderr: "Error: could not start HTTP service on port \(port) — \(error.localizedDescription)\n"),
                .daemonError
            )
        }

        let actualPort = await service.listeningPort ?? port
        let statusMsg = "HTTP search service running on http://localhost:\(actualPort)\n"

        // 4. Keep the service running until the calling task is cancelled
        //    (e.g. SIGINT from the CLI entry point). When cancelled,
        //    stop the service gracefully and return.
        let (cancelStream, cancelContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        await withTaskCancellationHandler {
            for await _ in cancelStream { break }
            await service.stop()
        } onCancel: {
            cancelContinuation.finish()
        }

        return (CLIOutput(stdout: statusMsg), .success)
    }
}
