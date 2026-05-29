import Foundation

// MARK: - IPCClientProtocol

/// Protocol abstracting IPC client communication.
///
/// Production uses `IPCClient` (Unix domain socket). Tests inject
/// `MockIPCClient` to verify CLIMain logic without a live daemon.
protocol IPCClientProtocol: Sendable {
    func send(_ request: IPCRequest) async throws -> IPCResponse
}

// MARK: - IPCClient + IPCClientProtocol

extension IPCClient: IPCClientProtocol {}
