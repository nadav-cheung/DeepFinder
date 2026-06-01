import Foundation
import Testing
@testable import DeepFinder

@Suite("ServeMode")
struct ServeModeTests {

    // MARK: - ArgParser: --serve flag

    @Test("--serve flag is recognized by ArgParser")
    func testServeFlagParsed() throws {
        let opts = try ArgParser.parse(["--serve"])
        #expect(opts.serveMode == true)
    }

    @Test("--serve defaults to false")
    func testServeDefaultFalse() throws {
        let opts = try ArgParser.parse([])
        #expect(opts.serveMode == false)
    }

    // MARK: - ArgParser: --port option

    @Test("--port parses port number")
    func testPortParsed() throws {
        let opts = try ArgParser.parse(["--serve", "--port", "8080"])
        #expect(opts.serveMode == true)
        #expect(opts.port == 8080)
    }

    @Test("--port without --serve still parses port")
    func testPortWithoutServe() throws {
        let opts = try ArgParser.parse(["--port", "9000", "query"])
        #expect(opts.port == 9000)
        #expect(opts.serveMode == false)
        #expect(opts.query == "query")
    }

    @Test("--port with non-integer value throws error")
    func testPortInvalidValue() {
        do {
            _ = try ArgParser.parse(["--port", "abc"])
            Issue.record("Expected invalidValue error")
        } catch let error as CLIError {
            if case .invalidValue(let flag, let value) = error {
                #expect(flag == "--port")
                #expect(value == "abc")
            } else {
                Issue.record("Expected invalidValue, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("--port without value throws error")
    func testPortMissingValue() {
        do {
            _ = try ArgParser.parse(["--port"])
            Issue.record("Expected missingValue error")
        } catch let error as CLIError {
            if case .missingValue(let flag) = error {
                #expect(flag == "--port")
            } else {
                Issue.record("Expected missingValue, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - CLIMain: --serve mode integration

    @Test("--serve with mock daemon starts HTTP service")
    func testServeModeWithMock() async {
        let mock = MockIPCClient(response: .stats(DaemonStats(
            totalFiles: 42,
            indexState: "live",
            uptimeSeconds: 100,
            memoryUsageMB: 50
        )))
        let task = Task {
            await CLIMain.run(args: ["--serve"], clientProvider: mock)
        }
        // Give the service time to start, then cancel to unblock
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let (output, exitCode) = await task.value
        #expect(exitCode == .success)
        #expect(output.stdout.contains("HTTP search service running on http://localhost:7654"))
    }

    @Test("--serve with --port uses specified port in output")
    func testServeWithPort() async {
        let mock = MockIPCClient(response: .stats(DaemonStats(
            totalFiles: 0,
            indexState: "live",
            uptimeSeconds: 0,
            memoryUsageMB: 0
        )))
        let task = Task {
            await CLIMain.run(args: ["--serve", "--port", "9090"], clientProvider: mock)
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let (output, exitCode) = await task.value
        #expect(exitCode == .success)
        #expect(output.stdout.contains("9090"))
    }

    // MARK: - HTTPSearchService: serve-mode integration

    @Test("HTTPSearchService can start and stop on custom port")
    func testHTTPServiceCustomPort() async throws {
        let service = HTTPSearchService(
            port: 19952,
            searchHandler: { _, _, _ in [] },
            statsHandler: { ["totalFiles": 0] }
        )
        try await service.start()
        let port = await service.listeningPort
        #expect(port == 19952)
        await service.stop()
        let running = await service.isRunning
        #expect(running == false)
    }
}
