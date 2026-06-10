import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderServices

// MARK: - IPCClientProtocol

/// Protocol abstracting IPC client communication.
///
/// Production uses `IPCClient` (Unix domain socket). Tests inject
/// `MockIPCClient` to verify CLIMain logic without a live daemon.
public protocol IPCClientProtocol: Sendable {
    func send(_ request: IPCRequest) async throws -> IPCResponse
}

// MARK: - IPCClient + IPCClientProtocol

extension IPCClient: IPCClientProtocol {}
