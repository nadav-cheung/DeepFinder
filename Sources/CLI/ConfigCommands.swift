// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderServices

// MARK: - ConfigCommandRunner

/// Executes `deepfinder config` subcommands.
///
/// All operations delegate to the daemon via IPC (configGet/configSet).
/// The runner formats output for display and returns exit codes.
public struct ConfigCommandRunner {

    // MARK: - get

    /// Get a single config key and display its value.
    ///
    /// - Parameters:
    ///   - key: Configuration key name.
    ///   - client: IPC client for daemon communication.
    ///   - output: Output writer for display.
    /// - Returns: Exit code (0 = success, non-zero = error).
    public static func get(
        key: String,
        client: any IPCClientProtocol,
        output: any CLIOutputWriter
    ) async -> Int32 {
        let request = IPCRequest.configGet(key: key)
        let response: IPCResponse
        do {
            response = try await client.send(request)
        } catch {
            output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            return 2
        }

        switch response {
        case .configValue(let value):
            output.write("\(value)\n")
            return 0
        case .ack:
            output.writeError("Error: key not found\n")
            return 1
        case .error(let ipcError):
            output.writeError("Error: \(ipcError)\n")
            return 3
        default:
            output.writeError("Error: unexpected response from daemon\n")
            return 2
        }
    }

    // MARK: - set

    /// Set a config key to a given value via IPC.
    ///
    /// - Parameters:
    ///   - key: Configuration key name.
    ///   - value: New value for the key.
    ///   - client: IPC client for daemon communication.
    ///   - output: Output writer for display.
    /// - Returns: Exit code (0 = success, non-zero = error).
    public static func set(
        key: String,
        value: String,
        client: any IPCClientProtocol,
        output: any CLIOutputWriter
    ) async -> Int32 {
        let request = IPCRequest.configSet(key: key, value: value)
        let response: IPCResponse
        do {
            response = try await client.send(request)
        } catch {
            output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            return 2
        }

        switch response {
        case .ack:
            output.write("OK\n")
            return 0
        case .error(let ipcError):
            output.writeError("Error: \(ipcError)\n")
            return 3
        default:
            output.writeError("Error: unexpected response from daemon\n")
            return 2
        }
    }

    // MARK: - list

    /// List all configuration items.
    ///
    /// Sends a configGet with nil key (meaning "get all") to the daemon.
    ///
    /// - Parameters:
    ///   - client: IPC client for daemon communication.
    ///   - output: Output writer for display.
    /// - Returns: Exit code (0 = success, non-zero = error).
    public static func list(
        client: any IPCClientProtocol,
        output: any CLIOutputWriter
    ) async -> Int32 {
        let request = IPCRequest.configGet(key: nil)
        let response: IPCResponse
        do {
            response = try await client.send(request)
        } catch {
            output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            return 2
        }

        switch response {
        case .configValue(let jsonString):
            // Daemon returned all config as JSON — display as key-value table
            if let data = jsonString.data(using: .utf8),
               let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                    output.write("  \(key)\t\(value)\n")
                }
            } else {
                output.write("\(jsonString)\n")
            }
            return 0
        case .error(let ipcError):
            output.writeError("Error: \(ipcError)\n")
            return 3
        default:
            output.writeError("Error: unexpected response from daemon\n")
            return 2
        }
    }

    // MARK: - reset

    /// Reset all configuration to defaults.
    ///
    /// Sends configSet for each default key via IPC.
    /// In production, prompts the user for confirmation.
    /// In tests, pass `confirm: true` to skip the prompt.
    ///
    /// - Parameters:
    ///   - client: IPC client for daemon communication.
    ///   - output: Output writer for display.
    ///   - confirm: If `true`, skip the confirmation prompt (for testing).
    /// - Returns: Exit code (0 = success, non-zero = error).
    public static func reset(
        client: any IPCClientProtocol,
        output: any CLIOutputWriter,
        confirm: Bool = false
    ) async -> Int32 {
        if !confirm {
            output.write("Reset all configuration to defaults? [y/N] ")
            let input = FileHandle.standardInput.availableData
            guard let response = String(data: input, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  response == "y" || response == "yes" else {
                output.write("Cancelled.\n")
                return 0
            }
        }

        let defaults = DaemonConfig.defaults
        let resetEntries: [(key: String, value: String)] = [
            ("excludedPaths", (try? JSONEncoder().encode(defaults.excludedPaths))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"),
            ("indexBatchSize", String(defaults.indexBatchSize)),
            ("maxResults", String(defaults.maxResults)),
            ("configVersion", String(defaults.configVersion)),
        ]

        for entry in resetEntries {
            let request = IPCRequest.configSet(key: entry.key, value: entry.value)
            let response: IPCResponse
            do {
                response = try await client.send(request)
            } catch {
                output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
                return 2
            }

            if case .error(let ipcError) = response {
                output.writeError("Error setting \(entry.key): \(ipcError)\n")
                return 3
            }
        }

        output.write("Configuration reset to defaults.\n")
        return 0
    }
}
