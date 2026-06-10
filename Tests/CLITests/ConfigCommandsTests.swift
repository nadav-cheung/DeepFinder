import Testing
import Foundation
import DeepFinderDaemon
@testable import DeepFinderCLILib

@Suite("ConfigCommandRunner")
struct ConfigCommandsTests {

    // MARK: - Helpers

    /// Creates a mock that responds to configGet with a specific config value.
    private func makeConfigGetMock(key: String, value: String?) -> MockIPCClient {
        // For configGet, we return .ack to simulate the daemon accepting the request.
        // In a real daemon, configGet would return a config value response.
        // The CLI runner formats the output based on the IPC response.
        MockIPCClient(response: .ack)
    }

    // MARK: - 1. get existing key returns value

    @Test("get existing key sends configGet request and returns success")
    func testGetExistingKey() async {
        let mock = MockIPCClient(response: .configValue("500"))
        let output = CapturingOutput()

        let exitCode = await ConfigCommandRunner.get(
            key: "maxResults",
            client: mock,
            output: output
        )

        #expect(exitCode == 0)

        // Verify the correct IPC request was sent
        let lastReq = await mock.lastRequest
        #expect(lastReq != nil)
        if case .configGet(let k) = lastReq! {
            #expect(k == "maxResults")
        } else {
            Issue.record("Expected configGet request, got: \(String(describing: lastReq))")
        }
    }

    // MARK: - 2. get non-existent key returns error

    @Test("get non-existent key returns error exit code")
    func testGetNonExistentKey() async {
        let mock = MockIPCClient(response: .error(.invalidRequest("Unknown configuration key")))
        let output = CapturingOutput()

        let exitCode = await ConfigCommandRunner.get(
            key: "nonexistent",
            client: mock,
            output: output
        )

        #expect(exitCode != 0)
        #expect(output.collected.contains("Error"))
    }

    // MARK: - 3. set key persists via IPC

    @Test("set key sends configSet request via IPC")
    func testSetKey() async {
        let mock = MockIPCClient(response: .ack)
        let output = CapturingOutput()

        let exitCode = await ConfigCommandRunner.set(
            key: "maxResults",
            value: "500",
            client: mock,
            output: output
        )

        #expect(exitCode == 0)

        let lastReq = await mock.lastRequest
        #expect(lastReq != nil)
        if case .configSet(let k, let v) = lastReq! {
            #expect(k == "maxResults")
            #expect(v == "500")
        } else {
            Issue.record("Expected configSet request, got: \(String(describing: lastReq))")
        }

        #expect(output.collected.contains("OK"))
    }

    // MARK: - 4. list shows all config items

    @Test("list sends configGet with nil key and returns success")
    func testListConfig() async {
        let mock = MockIPCClient(response: .configValue("{}"))
        let output = CapturingOutput()

        let exitCode = await ConfigCommandRunner.list(
            client: mock,
            output: output
        )

        #expect(exitCode == 0)

        // Verify the IPC request asks for all config
        let lastReq = await mock.lastRequest
        #expect(lastReq != nil)
        if case .configGet(let k) = lastReq! {
            #expect(k == nil) // nil key means "get all"
        } else {
            Issue.record("Expected configGet request with nil key, got: \(String(describing: lastReq))")
        }
    }

    // MARK: - 5. reset clears to defaults

    @Test("reset sends configSet for each default and returns success")
    func testResetConfig() async {
        let defaults = DaemonConfig.defaults
        // The reset command sets each key back to its default value
        let mock = MockConfigResetClient()
        let output = CapturingOutput()

        let exitCode = await ConfigCommandRunner.reset(
            client: mock,
            output: output,
            confirm: true // Skip confirmation prompt in test
        )

        #expect(exitCode == 0)

        // Verify all default keys were set
        let requests = await mock.capturedRequests
        #expect(requests.count > 0)

        // Should contain configSet for all known keys
        let setKeys = requests.compactMap { req -> String? in
            if case .configSet(let k, _) = req { return k }
            return nil
        }
        #expect(setKeys.contains("excludedPaths"))
        #expect(setKeys.contains("indexBatchSize"))
        #expect(setKeys.contains("maxResults"))
    }

    // MARK: - 6. IPC error handling

    @Test("IPC error during get returns non-zero exit code")
    func testIPCErrorHandling() async {
        let mock = MockIPCClient(error: IPCClientError.notConnected)
        let output = CapturingOutput()

        let exitCode = await ConfigCommandRunner.get(
            key: "maxResults",
            client: mock,
            output: output
        )

        #expect(exitCode != 0)
        #expect(output.collected.contains("Error"))
    }
}

// MARK: - Test Helpers for ConfigCommands

/// Capturing output writer for testing ConfigCommandRunner.
final class CapturingOutput: CLIOutputWriter, @unchecked Sendable {
    nonisolated(unsafe) private var buffer: [String] = []

    func write(_ text: String) {
        buffer.append(text)
    }

    func writeError(_ text: String) {
        buffer.append(text)
    }

    var collected: String {
        buffer.joined()
    }
}

/// Mock IPCClient that captures all requests (for reset which sends multiple).
actor MockConfigResetClient: IPCClientProtocol {
    var capturedRequests: [IPCRequest] = []

    func send(_ request: IPCRequest) async throws -> IPCResponse {
        capturedRequests.append(request)
        return .ack
    }
}
