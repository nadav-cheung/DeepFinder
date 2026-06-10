import Testing
import Foundation
import DeepFinderIndex
@testable import DeepFinderFS

struct FileScannerTests {

    // MARK: - Helpers

    /// Create a unique temp directory for a test.
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileScannerTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Collect all events from a scan into categorized arrays for easy assertion.
    private func collectEvents(
        rootPaths: [String],
        config: ScanConfiguration = ScanConfiguration()
    ) async -> (
        files: [FileRecord],
        directories: [FileRecord],
        errors: [ScanError],
        stats: ScanStats?,
        progressEvents: [Int]
    ) {
        let scanner = FileScanner()
        var files: [FileRecord] = []
        var directories: [FileRecord] = []
        var errors: [ScanError] = []
        var stats: ScanStats?
        var progressEvents: [Int] = []

        let stream = await scanner.scan(rootPaths: rootPaths, config: config)
        for await event in stream {
            switch event {
            case .fileFound(let record):
                files.append(record)
            case .directoryFound(let record):
                directories.append(record)
            case .scanComplete(let scanStats):
                stats = scanStats
            case .scanError(let error):
                errors.append(error)
            case .progress(let count):
                progressEvents.append(count)
            }
        }
        return (files, directories, errors, stats, progressEvents)
    }

    /// Create a file with optional content in the given directory.
    @discardableResult
    private func createFile(
        _ relativePath: String,
        in baseDir: URL,
        content: Data = Data("test".utf8)
    ) -> URL {
        let url = baseDir.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! content.write(to: url)
        return url
    }

    /// Create a directory in the given parent directory.
    @discardableResult
    private func createDirectory(_ relativePath: String, in baseDir: URL) -> URL {
        let url = baseDir.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Tests

    @Test func scanEmptyDirectory() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let emptyDir = tempDir.appendingPathComponent("empty")
        try! FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let result = await collectEvents(rootPaths: [emptyDir.path])

        #expect(result.files.count == 0)
        #expect(result.directories.count == 0)
        #expect(result.stats != nil)
        #expect(result.stats?.filesScanned == 0)
        #expect(result.stats?.directoriesScanned == 0)
        #expect(result.stats?.errorCount == 0)
    }

    @Test func scanSingleFile() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        createFile("hello.txt", in: tempDir, content: Data("hello world".utf8))

        let result = await collectEvents(rootPaths: [tempDir.path])

        #expect(result.files.count == 1)
        let record = result.files.first!
        #expect(record.name == "hello.txt")
        // The enumerator may resolve symlinks in the path (/var to /private/var).
        // Compare using hasSuffix which works regardless of symlink resolution.
        #expect(record.path.hasSuffix("hello.txt"))
        #expect(!record.isDirectory)
        #expect(record.size == 11) // "hello world" = 11 bytes
        #expect(record.extension == "txt")
    }

    @Test func scanNestedDirectories() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        createFile("a/file1.txt", in: tempDir)
        createFile("a/b/file2.txt", in: tempDir)
        createFile("a/b/c/file3.txt", in: tempDir)

        let result = await collectEvents(rootPaths: [tempDir.path])

        // 3 files at various nesting levels
        #expect(result.files.count == 3)
        let fileNames = Set(result.files.map(\.name))
        #expect(fileNames.contains("file1.txt"))
        #expect(fileNames.contains("file2.txt"))
        #expect(fileNames.contains("file3.txt"))

        // Directories: a, a/b, a/b/c
        #expect(result.directories.count == 3)
        let dirNames = Set(result.directories.map(\.name))
        #expect(dirNames.contains("a"))
        #expect(dirNames.contains("b"))
        #expect(dirNames.contains("c"))
    }

    @Test func skipGitDirectory() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        createFile("src/main.swift", in: tempDir)
        createFile("src/.git/objects/abc", in: tempDir)
        createFile(".git/HEAD", in: tempDir)

        var config = ScanConfiguration()
        config.skipPaths = ["/.git"]
        let result = await collectEvents(rootPaths: [tempDir.path], config: config)

        // main.swift found, .git contents skipped
        #expect(result.files.count == 1)
        #expect(result.files.first?.name == "main.swift")
    }

    @Test func skipNodeModules() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        createFile("package.json", in: tempDir)
        createFile("node_modules/lodash/index.js", in: tempDir)
        createFile("node_modules/react/index.js", in: tempDir)

        var config = ScanConfiguration()
        config.skipPaths = ["/node_modules"]
        let result = await collectEvents(rootPaths: [tempDir.path], config: config)

        #expect(result.files.count == 1)
        #expect(result.files.first?.name == "package.json")
    }

    @Test func skipSystemDirectory() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a mock "System" dir inside temp to test skip logic
        createFile("System/Library/test.bin", in: tempDir)
        createFile("good.txt", in: tempDir)

        var config = ScanConfiguration()
        config.skipPaths = ["/System"]
        let result = await collectEvents(rootPaths: [tempDir.path], config: config)

        #expect(result.files.count == 1)
        #expect(result.files.first?.name == "good.txt")
    }

    @Test func skipPrivacyPaths() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Simulate privacy paths under temp directory
        createFile("Library/Caches/com.apple.test/cache.db", in: tempDir)
        createFile("Library/Cookies/com.apple.test.cookies", in: tempDir)
        createFile("Library/Keychains/test.keychain", in: tempDir)
        createFile("normal.txt", in: tempDir)

        var config = ScanConfiguration()
        config.privacySkipPaths = ["/Library/Caches", "/Library/Cookies", "/Library/Keychains"]
        let result = await collectEvents(rootPaths: [tempDir.path], config: config)

        #expect(result.files.count == 1)
        #expect(result.files.first?.name == "normal.txt")
    }

    @Test func scanStats() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        createFile("file1.txt", in: tempDir)
        createFile("file2.txt", in: tempDir)
        createDirectory("subdir", in: tempDir)

        let result = await collectEvents(rootPaths: [tempDir.path])

        #expect(result.stats != nil)
        #expect(result.stats?.filesScanned == 2)
        #expect(result.stats?.directoriesScanned == 1)
        #expect((result.stats?.duration ?? 0) > 0)
        #expect(result.stats?.errorCount == 0)
    }

    @Test func nfcNormalization() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // "e" + combining acute accent (U+0301) to NFC should be "e" (U+00E9)
        let decomposed = "e\u{0301}xample.txt"
        let fileURL = tempDir.appendingPathComponent(decomposed)
        try! FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! Data("test".utf8).write(to: fileURL)

        let result = await collectEvents(rootPaths: [tempDir.path])

        #expect(result.files.count == 1)
        let record = result.files.first!
        // name should be NFC-normalized: "example.txt" (precomposed)
        let nfcExpected = "\u{00E9}xample.txt"
        #expect(record.name == nfcExpected)
        // originalName preserves the original decomposed form
        #expect(record.originalName == decomposed)
    }

    @Test func permissionDeniedSkipped() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a file, then make parent directory unreadable to trigger permission error.
        // We create a subdirectory, put a file in it, then revoke read permission.
        let restrictedDir = tempDir.appendingPathComponent("restricted")
        try! FileManager.default.createDirectory(at: restrictedDir, withIntermediateDirectories: true)
        let innerFile = restrictedDir.appendingPathComponent("secret.txt")
        try! Data("secret".utf8).write(to: innerFile)

        // Remove read permission on the directory
        try! FileManager.default.setAttributes(
            [.posixPermissions: Int16(0o000)],
            ofItemAtPath: restrictedDir.path
        )
        defer {
            // Restore permissions so cleanup can succeed
            try? FileManager.default.setAttributes(
                [.posixPermissions: Int16(0o755)],
                ofItemAtPath: restrictedDir.path
            )
        }

        let result = await collectEvents(rootPaths: [tempDir.path])

        // The restricted dir itself may or may not be found depending on enumeration
        // behavior, but inner file should NOT be found. Error count should be >= 1.
        let innerFound = result.files.contains { $0.name == "secret.txt" }
        #expect(!innerFound, "Files in unreadable directories should not appear in results")
        #expect((result.stats?.errorCount ?? 0) >= 1)
        #expect(result.errors.count >= 1)
    }

    @Test func fileRecordFieldsPopulated() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content = Data("Hello, World!".utf8) // 13 bytes
        createFile("docs/report.pdf", in: tempDir, content: content)

        let result = await collectEvents(rootPaths: [tempDir.path])

        #expect(result.files.count == 1)
        let record = result.files.first!
        #expect(record.name == "report.pdf")
        #expect(record.originalName == "report.pdf")
        // The enumerator may resolve symlinks in the path (/var to /private/var).
        // Compare using hasSuffix which works regardless of symlink resolution.
        #expect(record.path.hasSuffix("docs/report.pdf"))
        #expect(!record.isDirectory)
        #expect(record.size == 13)
        #expect(record.extension == "pdf")
        // ID should be assigned
        #expect(record.id > 0)
        // Dates should be reasonable (not far in the past/future)
        let now = Date()
        #expect(record.createdAt <= now)
        #expect(record.modifiedAt <= now)
        // parentPath should point to the containing directory
        #expect(record.parentPath.hasSuffix("docs"))
    }

    @Test func symlinkNotFollowed() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetFile = createFile("real.txt", in: tempDir)
        let linkURL = tempDir.appendingPathComponent("link.txt")
        try! FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: targetFile.path
        )

        var config = ScanConfiguration()
        config.followSymlinks = false
        let result = await collectEvents(rootPaths: [tempDir.path], config: config)

        // real.txt should be found, symlink should NOT be followed
        let names = result.files.map(\.name)
        #expect(names.contains("real.txt"), "Real file should be found")
        // The symlink itself should not appear as a regular file when followSymlinks is false
        // (symlinks are skipped, not followed)
        // The key invariant: we don't traverse through the symlink
        #expect(result.files.count == 1, "Only the real file, not symlink target content")
    }

    @Test func progressEventsEmitted() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create several files to ensure progress events are generated
        for i in 0..<20 {
            createFile("file_\(i).txt", in: tempDir, content: Data("x".utf8))
        }

        let result = await collectEvents(rootPaths: [tempDir.path])

        // Should have at least one progress event for 20 files
        #expect(result.progressEvents.count > 0, "Progress events should be emitted during scan")
        // Progress should be monotonically non-decreasing
        for i in 1..<result.progressEvents.count {
            #expect(
                result.progressEvents[i] >= result.progressEvents[i - 1],
                "Progress counts should be non-decreasing"
            )
        }
    }

    // MARK: - Concurrent Scan Guard

    @Test func concurrentScanReturnsEmptyStream() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        createFile("a.txt", in: tempDir)
        createFile("b.txt", in: tempDir)

        let scanner = FileScanner()

        // Start the first scan
        let stream1 = await scanner.scan(rootPaths: [tempDir.path], config: ScanConfiguration())

        // While the first scan is in progress, start a second scan on the same scanner.
        let stream2 = await scanner.scan(rootPaths: [tempDir.path], config: ScanConfiguration())

        // Collect events from stream2 — should be empty since a scan is already active.
        var stream2Events: [ScanEvent] = []
        for await event in stream2 {
            stream2Events.append(event)
        }

        // stream2 should produce zero events (empty stream returned by guard).
        #expect(stream2Events.isEmpty, "Second concurrent scan should return an empty stream")

        // Now drain stream1 to completion so the guard resets.
        var stream1Files: [FileRecord] = []
        for await event in stream1 {
            if case .fileFound(let record) = event {
                stream1Files.append(record)
            }
        }
        #expect(stream1Files.count == 2, "First scan should find both files")
    }

    @Test func sequentialScansProduceUniqueIDs() async {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        createFile("first.txt", in: tempDir)
        createFile("second.txt", in: tempDir)

        let scanner = FileScanner()

        // Run first scan to completion
        let stream1 = await scanner.scan(rootPaths: [tempDir.path], config: ScanConfiguration())
        var ids1: [UInt32] = []
        for await event in stream1 {
            if case .fileFound(let record) = event {
                ids1.append(record.id)
            }
        }

        // Run second scan to completion — IDs should not overlap with first scan
        let stream2 = await scanner.scan(rootPaths: [tempDir.path], config: ScanConfiguration())
        var ids2: [UInt32] = []
        for await event in stream2 {
            if case .fileFound(let record) = event {
                ids2.append(record.id)
            }
        }

        // Both scans should have found files
        #expect(!ids1.isEmpty, "First scan should find files")
        #expect(!ids2.isEmpty, "Second scan should find files")

        // No overlap between ID sets
        let set1 = Set(ids1)
        let set2 = Set(ids2)
        let overlap = set1.intersection(set2)
        #expect(overlap.isEmpty, "Sequential scans must not produce overlapping IDs: \(overlap)")
    }
}
