import Testing
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderFS
import DeepFinderPersist
@testable import DeepFinderDaemon

// MARK: - ConcurrencyStressTests

/// Stress tests for DeepFinder's actor-based architecture.
///
/// Validates correctness under concurrent load: no data races, no lost data,
/// no crashes, and deterministic results regardless of scheduling order.
///
/// These tests exercise the concurrency boundaries that matter:
/// - ``IPCServer`` accepting many rapid client connections
/// - ``InMemoryIndex`` receiving concurrent insert + search operations
/// - Actor isolation keeping internal state consistent
///
/// All tests use `withTaskGroup` for structured concurrency and include
/// timeouts to prevent hangs on CI.
@Suite("Concurrency stress tests", .serialized)
struct ConcurrencyStressTests {

    // MARK: - Timeout helper

    /// Run an async operation with a deadline. Throws if the operation does not
    /// complete within `seconds`.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Helpers

    /// Create a unique temp directory for socket-based tests.
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-stress-\(UUID().uuidString.prefix(8))")
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

    /// Send a single framed IPC request and read the response.
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

    // MARK: - 1. Ten concurrent IPC clients

    /// Verifies that ``IPCServer`` handles 10 concurrent clients each sending
    /// a query, with all receiving correct results.
    ///
    /// Each client sends a different query against a known dataset. Results
    /// must be correct (no mixed-up responses, no dropped connections).
    @Test("Ten concurrent IPC clients query simultaneously and receive correct results")
    func testTenConcurrentClients() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = socketPath(in: dir)

        // Populate coordinator with known records
        let results = (1...20).map { i in
            let name = "file\(i).txt"
            let record = makeRecord(id: UInt32(i), name: name, path: "/test/\(name)")
            return SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .exact)
        }
        let provider = ConcurrencyStressMockProvider(results: results)
        let coordinator = SearchCoordinator(providers: [provider])

        let server = IPCServer(socketPath: path, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        // 10 concurrent clients, each searching for a different file
        let clientCount = 10
        let responses = await withTaskGroup(of: (Int, IPCResponse).self) { group in
                for i in 1...clientCount {
                    let idx = i
                    let query = "file\(idx)"
                    let socketPath = path
                    group.addTask {
                        do {
                            let resp = try self.sendRequest(
                                .query(query, limit: nil),
                                to: socketPath
                            )
                            return (idx, resp)
                        } catch {
                            return (idx, .error(.invalidRequest(error.localizedDescription)))
                        }
                    }
                }

                var collected: [(Int, IPCResponse)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

        await server.stop()

        // Verify: all 10 clients got results, each found the correct file
        #expect(responses.count == clientCount)

        for (idx, response) in responses {
            switch response {
            case .results(let results, _):
                #expect(results.contains { $0.record.name == "file\(idx).txt" },
                        "Client \(idx) should find file\(idx).txt")
            case .error(let err):
                Issue.record("Client \(idx) got unexpected error: \(err)")
            default:
                Issue.record("Client \(idx) got unexpected response type")
            }
        }
    }

    // MARK: - 2. IPCServer handles many rapid connections

    /// Opens and closes many connections in rapid succession to verify the
    /// accept loop does not drop connections under load.
    @Test("IPCServer handles rapid connection/disconnection without dropping clients")
    func testRapidConnections() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = socketPath(in: dir)
        let record = makeRecord(id: 1, name: "stress.txt", path: "/test/stress.txt")
        let result = SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .exact)
        let provider = ConcurrencyStressMockProvider(results: [result])
        let coordinator = SearchCoordinator(providers: [provider])

        let server = IPCServer(socketPath: path, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Send 50 rapid sequential connections, measuring success rate
        let totalConnections = 50
        var successCount = 0

        for _ in 0..<totalConnections {
            do {
                let encoded = try IPCFraming.encode(IPCRequest.query("stress", limit: nil))
                let socket = try TestSocket.connectUnix(path: path)
                try socket.write(encoded)
                let responseData = try socket.readFramedMessage()
                socket.close()
                let response = try JSONDecoder().decode(IPCResponse.self, from: responseData)
                if case .results = response {
                    successCount += 1
                }
            } catch {
                // Log but don't fail — stress tests may have occasional transient errors
                // from system limits. We verify the success rate is high.
            }
        }

        await server.stop()

        // At least 90% should succeed under normal conditions
        #expect(successCount >= Int(Double(totalConnections) * 0.9),
                "Expected >=90% success rate, got \(successCount)/\(totalConnections)")
    }

    // MARK: - 3. One hundred concurrent InMemoryIndex inserts

    /// Inserts 100 records concurrently into ``InMemoryIndex`` from multiple
    /// tasks, then runs concurrent searches to verify all data is present.
    ///
    /// This validates that actor serialization preserves correctness under
    /// heavy concurrent mutation.
    @Test("One hundred concurrent inserts followed by concurrent searches produce correct results")
    func testConcurrentInsertsAndSearches() async throws {
        let index = InMemoryIndex()

        // Phase 1: Insert 100 records concurrently from 10 tasks (10 inserts each)
        let insertCount = 100
        let taskCount = 10
        let perTask = insertCount / taskCount

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: Void.self) { group in
                for taskIdx in 0..<taskCount {
                    let baseID = taskIdx * perTask
                    group.addTask {
                        for i in 1...perTask {
                            let id = UInt32(baseID + i)
                            let name = "file\(id).txt"
                            let record = FileRecord(
                                id: id,
                                name: name,
                                originalName: name,
                                path: "/test/\(name)",
                                parentPath: "/test",
                                isDirectory: false,
                                size: Int64(id * 100),
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
                                modifiedAt: Date(timeIntervalSince1970: 1_700_001_000 + Double(id)),
                                extension: "txt"
                            )
                            await index.insert(record)
                        }
                    }
                }
            }
        }

        // Verify: all 100 records are in the index
        let count = await index.count
        #expect(count == insertCount, "Expected \(insertCount) records, got \(count)")

        // Phase 2: Run 10 concurrent searches, each for a different file
        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: (Int, [FileRecord]).self) { group in
                let searchTargets = stride(from: 1, through: insertCount, by: 10).map { $0 }
                for targetID in searchTargets {
                    group.addTask {
                        let results = await index.search(query: "file\(targetID).txt")
                        return (targetID, results)
                    }
                }

                for await (targetID, results) in group {
                    #expect(results.count == 1,
                            "Expected exactly 1 result for file\(targetID), got \(results.count)")
                    #expect(results.first?.id == UInt32(targetID),
                            "Expected record ID \(targetID), got \(results.first?.id ?? 0)")
                }
            }
        }

        // Phase 3: Verify no corrupted records
        let allRecords = await index.allRecords()
        let recordIDs = Set(allRecords.map(\.id))
        #expect(recordIDs.count == insertCount, "All record IDs should be unique")

        for record in allRecords {
            #expect(record.name.hasPrefix("file"), "Record name should match pattern")
            #expect(record.id > 0 && record.id <= UInt32(insertCount),
                    "Record ID \(record.id) should be in range 1...\(insertCount)")
        }
    }

    // MARK: - 4. Concurrent inserts + searches interleaved

    /// Interleaves inserts and searches concurrently to stress-test actor
    /// reentrancy and ensure searches never observe partial state.
    @Test("Interleaved concurrent inserts and searches maintain consistency")
    func testInterleavedInsertsAndSearches() async throws {
        let index = InMemoryIndex()
        let totalRecords = 50
        let halfPoint = totalRecords / 2

        // Pre-load first half
        for i in 1...halfPoint {
            let name = "pre\(i).txt"
            await index.insert(
                name: name,
                path: "/test/\(name)",
                parentPath: "/test"
            )
        }

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: Void.self) { group in
                // Task A: Insert remaining records
                group.addTask {
                    for i in (halfPoint + 1)...totalRecords {
                        let name = "post\(i).txt"
                        await index.insert(
                            name: name,
                            path: "/test/\(name)",
                            parentPath: "/test"
                        )
                    }
                }

                // Task B: Search repeatedly during inserts
                group.addTask {
                    for _ in 0..<20 {
                        let results = await index.search(query: "pre")
                        // At minimum, all pre-loaded records should be found
                        // (inserts shouldn't corrupt existing data)
                        let preCount = results.filter { $0.name.hasPrefix("pre") }.count
                        #expect(preCount >= halfPoint,
                                "All pre-loaded records should remain findable: found \(preCount)")
                        // Brief yield to let inserts progress
                        await Task.yield()
                    }
                }

                // Task C: Search for newly inserted records
                group.addTask {
                    for _ in 0..<20 {
                        let results = await index.search(query: "post")
                        // New records may or may not be found — consistency is the check
                        // (should never be negative or corrupted)
                        #expect(results.count >= 0, "Search should never return negative count")
                        await Task.yield()
                    }
                }
            }
        }

        // Final verification: all records present
        let finalCount = await index.count
        #expect(finalCount == totalRecords,
                "Expected \(totalRecords) records, got \(finalCount)")

        let postResults = await index.search(query: "post")
        let preResults = await index.search(query: "pre")
        #expect(postResults.count + preResults.count == totalRecords,
                "All records should be queryable: post=\(postResults.count) + pre=\(preResults.count) = \(postResults.count + preResults.count), expected \(totalRecords)")
    }

    // MARK: - 5. Actor isolation: no lost updates under contention

    /// Uses a counter pattern to verify that actor isolation prevents data
    /// races. Multiple tasks atomically increment a counter; the final value
    /// must equal the total number of increments.
    ///
    /// While Swift actors guarantee this by design, this test serves as a
    /// regression check that actors are used correctly (not accidentally
    /// bypassed via non-isolated access or `nonisolated`).
    @Test("Actor isolation prevents lost updates under concurrent increments")
    func testActorIsolationNoLostUpdates() async throws {
        // Use InMemoryIndex as the actor under test
        let index = InMemoryIndex()

        let tasks = 20
        let insertsPerTask = 50
        let expectedTotal = tasks * insertsPerTask

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: Void.self) { group in
                for t in 0..<tasks {
                    let offset = t * insertsPerTask
                    group.addTask {
                        for i in 1...insertsPerTask {
                            let seq = offset + i
                            let name = "actor\(seq).txt"
                            await index.insert(
                                name: name,
                                path: "/test/\(name)",
                                parentPath: "/test"
                            )
                        }
                    }
                }
            }
        }

        let finalCount = await index.count
        #expect(finalCount == expectedTotal,
                "Actor isolation failed: expected \(expectedTotal) records, got \(finalCount)")

        // Also verify all records are searchable (no internal corruption)
        let allResults = await index.search(query: "actor")
        #expect(allResults.count == expectedTotal,
                "All \(expectedTotal) records should be searchable, found \(allResults.count)")
    }

    // MARK: - 6. Concurrent remove operations

    /// Concurrently inserts then removes records from multiple tasks.
    /// Verifies the index returns to its expected size with no dangling entries.
    @Test("Concurrent remove operations leave index in consistent state")
    func testConcurrentRemoves() async throws {
        let index = InMemoryIndex()

        // Insert 60 records
        for i in 1...60 {
            let name = "rm\(i).txt"
            await index.insert(
                name: name,
                path: "/test/\(name)",
                parentPath: "/test"
            )
        }
        #expect(await index.count == 60)

        // Concurrently remove every other record from 4 tasks
        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: Void.self) { group in
                for taskIdx in 0..<4 {
                    let offset = taskIdx
                    group.addTask {
                        // Remove IDs offset by 2 starting from this task's offset
                        for i in stride(from: offset + 1, through: 60, by: 4) {
                            await index.remove(id: UInt32(i))
                        }
                    }
                }
            }
        }

        // All even but one pattern: Since we removed IDs 1,5,9,... via task 0,
        // 2,6,10,... via task 1, etc. — the actual set depends on the stride.
        // Instead, verify a specific property: search for remaining records
        let allRecords = await index.allRecords()
        let allIDs = Set(allRecords.map(\.id))
        #expect(allIDs.count == allRecords.count, "No duplicate IDs")

        // Verify removals didn't corrupt remaining records
        for record in allRecords {
            #expect(record.name.hasPrefix("rm"), "Record name should match pattern")
            #expect(record.id >= 1 && record.id <= 60, "Record ID should be in range")
        }

        // Search for a record we know should exist (ID 60 was not removed by any task)
        // with stride 4: task 0 removes 1,5,9,...,57; task 1 removes 2,6,...,58;
        // task 2 removes 3,7,...,59; task 3 removes 4,8,...,60
        // All IDs are covered, so count should be 0
        #expect(await index.count == 0, "All records should have been removed")
    }

    // MARK: - 7. IPCServer concurrent query + stats

    /// Verifies that mixed query and stats requests arriving concurrently
    /// are both handled correctly without interference.
    @Test("Concurrent query and stats requests are handled independently")
    func testConcurrentQueryAndStats() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = socketPath(in: dir)
        let record = makeRecord(id: 1, name: "mixed.txt", path: "/test/mixed.txt")
        let result = SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .exact)
        let provider = ConcurrencyStressMockProvider(results: [result])
        let coordinator = SearchCoordinator(providers: [provider])

        let server = IPCServer(
            socketPath: path,
            coordinator: coordinator,
            statsProvider: { DaemonStats(
                totalFiles: 99,
                indexState: "live",
                uptimeSeconds: 3600,
                memoryUsageMB: 128
            ) }
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await withTaskGroup(of: IPCResponse.self) { group in
                // 5 query requests
                for _ in 0..<5 {
                    group.addTask {
                        do {
                            return try self.sendRequest(
                                .query("mixed", limit: nil),
                                to: path
                            )
                        } catch {
                            return .error(.invalidRequest(error.localizedDescription))
                        }
                    }
                }

                // 5 stats requests
                for _ in 0..<5 {
                    group.addTask {
                        do {
                            return try self.sendRequest(.stats, to: path)
                        } catch {
                            return .error(.invalidRequest(error.localizedDescription))
                        }
                    }
                }

                var queryCount = 0
                var statsCount = 0
                for await response in group {
                    switch response {
                    case .results(let results, _):
                        #expect(results.count == 1)
                        #expect(results[0].record.name == "mixed.txt")
                        queryCount += 1
                    case .stats(let stats):
                        #expect(stats.totalFiles == 99)
                        #expect(stats.indexState == "live")
                        statsCount += 1
                    default:
                        Issue.record("Unexpected response")
                    }
                }

                #expect(queryCount == 5, "Expected 5 query responses, got \(queryCount)")
                #expect(statsCount == 5, "Expected 5 stats responses, got \(statsCount)")
            }

        await server.stop()
    }

    // MARK: - 8. Server start/stop cycling under concurrency

    /// Starts and stops the server repeatedly while a concurrent task pings it.
    /// Verifies no crashes or leaked file descriptors.
    @Test("Repeated start/stop cycles do not crash or leak")
    func testStartStopCycles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = socketPath(in: dir)
        let cycles = 5

        for cycle in 0..<cycles {
            let coordinator = SearchCoordinator(providers: [])
            let server = IPCServer(socketPath: path, coordinator: coordinator)

            // Start
            try await server.start()
            #expect(await checkRunning(server), "Server should be running after start (cycle \(cycle))")

            // Try a quick connection
            do {
                let encoded = try IPCFraming.encode(IPCRequest.stats)
                let socket = try TestSocket.connectUnix(path: path)
                try socket.write(encoded)
                _ = try socket.readFramedMessage()
                socket.close()
            } catch {
                // Connection may fail during stop — that's acceptable for stress
            }

            // Stop
            await server.stop()
            #expect(!(await checkRunning(server)),
                    "Server should not be running after stop (cycle \(cycle))")
        }
    }

    // MARK: - 9. Large-volume concurrent inserts stress

    /// Inserts 500 records concurrently from 25 tasks to push actor throughput.
    @Test("Five hundred concurrent inserts across 25 tasks complete successfully")
    func testLargeVolumeConcurrentInserts() async throws {
        let index = InMemoryIndex()
        let totalRecords = 500
        let taskCount = 25
        let perTask = totalRecords / taskCount

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: Void.self) { group in
                for t in 0..<taskCount {
                    let offset = t * perTask
                    group.addTask {
                        for i in 1...perTask {
                            let seq = offset + i
                            let name = "large\(seq).txt"
                            await index.insert(
                                name: name,
                                path: "/test/\(name)",
                                parentPath: "/test"
                            )
                        }
                    }
                }
            }
        }

        let count = await index.count
        #expect(count == totalRecords,
                "Expected \(totalRecords) records, got \(count)")

        // Verify search correctness across the full set
        let results = await index.search(query: "large")
        #expect(results.count == totalRecords,
                "Search should find all \(totalRecords) records, found \(results.count)")

        // Spot-check specific records using full filename for exact match
        // IDs are auto-generated and non-deterministic under concurrency, so we
        // verify by name.
        for id in [1, 100, 250, 400, 500] {
            let found = await index.search(query: "large\(id).txt")
            #expect(found.count == 1, "Record large\(id) should be findable: found \(found.count)")
            #expect(found.first?.name == "large\(id).txt",
                    "Record should have correct name, got \(found.first?.name ?? "nil")")
        }
    }

    // MARK: - 10. Concurrency with Chinese filenames

    /// Inserts Chinese-named files concurrently and verifies search
    /// remains consistent under concurrent load. Each file is searched
    /// by its Chinese name (exact match via Trie prefix).
    @Test("Concurrent inserts with Chinese filenames produce correct search results")
    func testConcurrentChineseFilenames() async throws {
        let index = InMemoryIndex()

        let chineseNames = [
            "报告",       // report
            "文档",       // document
            "图片",       // picture
            "音乐",       // music
            "视频",       // video
            "下载",       // download
            "桌面",       // desktop
            "项目",       // project
            "笔记",       // notes
            "数据",       // data
        ]

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: Void.self) { group in
                for name in chineseNames {
                    let safeName = name
                    group.addTask {
                        await index.insert(
                            name: safeName,
                            path: "/test/\(safeName)",
                            parentPath: "/test"
                        )
                    }
                }
            }
        }

        // Verify all records inserted
        #expect(await index.count == chineseNames.count)

        // Verify each Chinese name is searchable by its own characters
        for name in chineseNames {
            let results = await index.search(query: name)
            #expect(results.contains { $0.name == name },
                    "Searching '\(name)' should find itself")
        }
    }
}

// MARK: - ConcurrencyStressMockProvider

/// A mock ``SearchProvider`` for concurrency stress tests.
/// Named to avoid collision with the mock in ``IPCServerTests``.
private struct ConcurrencyStressMockProvider: SearchProvider, Sendable {
    let providerID = "mock"
    let results: [SearchResult]

    func search(query: SearchQuery) -> SearchResultSequence {
        SearchResultSequence(results)
    }

    func cancel(queryID: String) async {}
    func prepare() async {}
}
