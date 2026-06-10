import Testing
import Foundation
import DeepFinderIndex
import DeepFinderSearch
@testable import DeepFinderDaemon

@Suite("IPCServer Unix socket")
struct IPCServerTests {

    // MARK: - Helpers

    /// Create a unique temp directory for each test.
    /// Paths stay short because sockaddr_un.sun_path is limited to ~104 chars.
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Socket path inside the temp directory.
    private func socketPath(in dir: URL) -> String {
        dir.appendingPathComponent("s").path
    }

    /// Make a FileRecord for testing.
    private func makeRecord(id: UInt32, name: String, path: String) -> FileRecord {
        FileRecord(
            id: id,
            name: name.lowercased(),
            originalName: name,
            path: path,
            parentPath: (path as NSString).deletingLastPathComponent,
            isDirectory: false,
            size: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            extension: (name as NSString).pathExtension.isEmpty
                ? nil
                : (name as NSString).pathExtension
        )
    }

    /// A minimal test client that connects to the Unix socket,
    /// sends one framed IPCRequest, and reads one framed IPCResponse.
    private func sendRequest(
        _ request: IPCRequest,
        to path: String
    ) throws -> IPCResponse {
        let encoded = try IPCFraming.encode(request)

        let socket = try TestSocket.connectUnix(path: path)
        try socket.write(encoded)

        let response = try socket.readFramedMessage()
        socket.close()
        return try JSONDecoder().decode(IPCResponse.self, from: response)
    }

    /// Read `isRunning` from actor-isolated server.
    private func checkRunning(_ server: IPCServer) async -> Bool {
        await server.isRunning
    }

    // MARK: - 1. start() creates socket file

    @Test("start() creates socket file on disk")
    func testStartCreatesSocket() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let coordinator = SearchCoordinator(providers: [])
        let server = IPCServer(
            socketPath: socketPath(in: dir),
            coordinator: coordinator
        )

        try await server.start()
        #expect(FileManager.default.fileExists(atPath: socketPath(in: dir)))
        #expect(await checkRunning(server))
        await server.stop()
    }

    // MARK: - 2. stop() removes socket file

    @Test("stop() removes socket file")
    func testStopRemovesSocket() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let coordinator = SearchCoordinator(providers: [])
        let server = IPCServer(
            socketPath: socketPath(in: dir),
            coordinator: coordinator
        )

        try await server.start()
        #expect(FileManager.default.fileExists(atPath: socketPath(in: dir)))
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath(in: dir)))
        let running2 = await checkRunning(server)
        #expect(!running2)
    }

    // MARK: - 3. Client round-trip: query → results

    @Test("Client sends query request and receives results")
    func testQueryRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord(id: 1, name: "test.txt", path: "/tmp/test.txt")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let provider = MockSearchProvider(results: [result])
        let coordinator = SearchCoordinator(providers: [provider])

        let server = IPCServer(
            socketPath: socketPath(in: dir),
            coordinator: coordinator
        )
        try await server.start()

        // Brief pause to let accept loop start
        try await Task.sleep(nanoseconds: 50_000_000)

        let response = try await sendRequest(.query("test", limit: nil), to: socketPath(in: dir))
        await server.stop()

        switch response {
        case .results(let results, let queryID):
            #expect(results.count == 1)
            #expect(results[0].record.name == "test.txt")
            #expect(!queryID.isEmpty)
        case .error(let err):
            Issue.record("Expected results but got error: \(err)")
        default:
            Issue.record("Unexpected response type")
        }
    }

    // MARK: - 4. Stats request returns DaemonStats

    @Test("Client sends stats request and receives DaemonStats")
    func testStatsRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let coordinator = SearchCoordinator(providers: [])
        let server = IPCServer(
            socketPath: socketPath(in: dir),
            coordinator: coordinator,
            statsProvider: { DaemonStats(
                totalFiles: 42,
                indexState: "live",
                uptimeSeconds: 100.0,
                memoryUsageMB: 50.0
            ) }
        )

        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        let response = try await sendRequest(.stats, to: socketPath(in: dir))
        await server.stop()

        switch response {
        case .stats(let stats):
            #expect(stats.totalFiles == 42)
            #expect(stats.indexState == "live")
        default:
            Issue.record("Expected stats response")
        }
    }

    // MARK: - 5. Invalid JSON returns error response

    @Test("Invalid JSON over socket returns error response")
    func testInvalidJSONReturnsError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let coordinator = SearchCoordinator(providers: [])
        let server = IPCServer(
            socketPath: socketPath(in: dir),
            coordinator: coordinator
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Send raw garbage data with valid framing
        let garbage = Data("not valid json at all!!!".utf8)
        let framed = IPCFraming.addLengthPrefix(to: garbage)

        let socket = try TestSocket.connectUnix(path: socketPath(in: dir))
        try socket.write(framed)

        let response = try socket.readFramedMessage()
        socket.close()
        await server.stop()

        let decoded = try JSONDecoder().decode(IPCResponse.self, from: response)
        switch decoded {
        case .error:
            // Expected
            break
        default:
            Issue.record("Expected error response")
        }
    }

    // MARK: - 6. Multi-client concurrent connections

    @Test("Multiple clients can connect and query concurrently")
    func testMultiClient() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord(id: 1, name: "multi.txt", path: "/tmp/multi.txt")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let provider = MockSearchProvider(results: [result])
        let coordinator = SearchCoordinator(providers: [provider])

        let server = IPCServer(
            socketPath: socketPath(in: dir),
            coordinator: coordinator
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        let path = socketPath(in: dir)

        // 3 concurrent clients
        async let r1 = try sendRequest(.query("multi", limit: nil), to: path)
        async let r2 = try sendRequest(.query("multi", limit: nil), to: path)
        async let r3 = try sendRequest(.stats, to: path)

        let resp1 = try await r1
        let resp2 = try await r2
        let resp3 = try await r3
        await server.stop()

        // First two should be results
        if case .results(let results, _) = resp1 {
            #expect(results.count == 1)
        } else {
            Issue.record("Client 1 expected results")
        }
        if case .results(let results, _) = resp2 {
            #expect(results.count == 1)
        } else {
            Issue.record("Client 2 expected results")
        }
        // Third should be stats
        if case .stats(let stats) = resp3 {
            #expect(stats.totalFiles >= 0)
        } else {
            Issue.record("Client 3 expected stats")
        }
    }

    // MARK: - 7. Peer credential verification

    @Test("Peer credential verification accepts same-user connections")
    func testPeerCredentialVerificationPassesForSameUser() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord(id: 1, name: "secure.txt", path: "/tmp/secure.txt")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let provider = MockSearchProvider(results: [result])
        let coordinator = SearchCoordinator(providers: [provider])

        let server = IPCServer(
            socketPath: socketPath(in: dir),
            coordinator: coordinator
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Connect from the same process (same UID). Credential verification must pass.
        let response = try await sendRequest(.query("secure", limit: nil), to: socketPath(in: dir))
        await server.stop()

        switch response {
        case .results(let results, _):
            #expect(results.count == 1)
            #expect(results[0].record.name == "secure.txt")
            // Credential verification passed (same user)
        default:
            Issue.record("Expected results response, but got: \(response)")
        }
    }

    // MARK: - 8. Double stop is safe

    @Test("Double stop does not crash")
    func testDoubleStopSafe() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let coordinator = SearchCoordinator(providers: [])
        let server = IPCServer(
            socketPath: socketPath(in: dir),
            coordinator: coordinator
        )

        try await server.start()
        await server.stop()
        let runningAfterFirst = await checkRunning(server)
        #expect(!runningAfterFirst)
        // Second stop should be a no-op, not crash
        await server.stop()
        let runningAfterSecond = await checkRunning(server)
        #expect(!runningAfterSecond)
    }

    // MARK: - 9. Oversized query returns error over socket

    @Test("Oversized query returns error response over socket")
    func testOversizedQueryReturnsError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let coordinator = SearchCoordinator(providers: [])
        let server = IPCServer(
            socketPath: socketPath(in: dir),
            coordinator: coordinator
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Build a query that exceeds maxQueryLength (barely over the limit)
        let oversizedQuery = String(repeating: "a", count: maxQueryLength + 1)

        // Encode the request manually as raw JSON to bypass the IPCRequest
        // encoder (which doesn't validate length). This lets us send a query
        // that will be rejected by the decoder on the server side.
        let requestDict: [String: Any] = [
            "ipcProtocolVersion": 1,
            "kind": "query",
            "query": oversizedQuery
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: requestDict)
        let framed = IPCFraming.addLengthPrefix(to: jsonData)

        let socket = try TestSocket.connectUnix(path: socketPath(in: dir))
        try socket.write(framed)

        let responseData = try socket.readFramedMessage()
        socket.close()
        await server.stop()

        let response = try JSONDecoder().decode(IPCResponse.self, from: responseData)

        switch response {
        case .error(let err):
            if case .queryError(let msg) = err {
                #expect(msg.contains("too long") || msg.contains("max"))
            } else {
                Issue.record("Expected .queryError but got: \(err)")
            }
        default:
            Issue.record("Expected error response for oversized query, got: \(response)")
        }
    }

    // MARK: - 10. start() cleans up stale socket file

    @Test("start() cleans up pre-existing stale socket file")
    func testStartCleansStaleSocket() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = socketPath(in: dir)

        // Create a stale file at the socket path
        try Data().write(to: URL(fileURLWithPath: path))
        #expect(FileManager.default.fileExists(atPath: path))

        let coordinator = SearchCoordinator(providers: [])
        let server = IPCServer(socketPath: path, coordinator: coordinator)

        // start() should clean up the stale file and succeed
        try await server.start()
        #expect(await checkRunning(server))
        #expect(FileManager.default.fileExists(atPath: path))  // socket exists (new one)
        await server.stop()
    }
}

// MARK: - TestSocket

/// Errors thrown by ``TestSocket`` during test I/O operations.
private enum TestSocketError: Error {
    case connectionClosed
}

/// A simple blocking Unix domain socket client for tests.
final class TestSocket: @unchecked Sendable {
    private var fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Connect to a Unix domain socket at the given path.
    static func connectUnix(path: String) throws -> TestSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCServerError.socketCreationFailed(String(cString: strerror(errno)))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { pathPtr in
            _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { destPtr in
                strcpy(destPtr, pathPtr)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw IPCServerError.socketCreationFailed(err)
        }

        return TestSocket(fd: fd)
    }

    /// Write all data to the socket.
    func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                throw TestSocketError.connectionClosed
            }
            offset += written
        }
    }

    /// Read a 4-byte-length-prefixed framed message.
    func readFramedMessage() throws -> Data {
        // Read 4-byte header
        var header = Data(capacity: 4)
        while header.count < 4 {
            var buf = [UInt8](repeating: 0, count: 4 - header.count)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 {
                throw TestSocketError.connectionClosed
            }
            header.append(contentsOf: buf.prefix(n))
        }

        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard length > 0 else { return Data() }

        var payload = Data(capacity: length)
        while payload.count < length {
            let remaining = length - payload.count
            var buf = [UInt8](repeating: 0, count: min(remaining, 8192))
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 {
                throw TestSocketError.connectionClosed
            }
            payload.append(contentsOf: buf.prefix(n))
        }
        return payload
    }

    /// Close the socket.
    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

// MARK: - Mock SearchProvider

/// A simple mock SearchProvider for testing.
struct MockSearchProvider: SearchProvider, Sendable {
    let providerID = "mock"
    let results: [SearchResult]

    func search(query: SearchQuery) -> SearchResultSequence {
        SearchResultSequence(results)
    }

    func cancel(queryID: String) async {}
    func prepare() async {}
}
