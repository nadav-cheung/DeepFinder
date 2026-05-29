import XCTest
import Foundation
@testable import DeepFinder

final class FileScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileScannerTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

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

    /// Create a file with optional content in the temp directory.
    @discardableResult
    private func createFile(
        relativePath: String,
        content: Data = Data("test".utf8)
    ) -> URL {
        let url = tempDir.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! content.write(to: url)
        return url
    }

    /// Create a directory in the temp directory.
    @discardableResult
    private func createDirectory(relativePath: String) -> URL {
        let url = tempDir.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Tests

    func testScanEmptyDirectory() async {
        let emptyDir = tempDir.appendingPathComponent("empty")
        try! FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let result = await collectEvents(rootPaths: [emptyDir.path])

        XCTAssertEqual(result.files.count, 0)
        XCTAssertEqual(result.directories.count, 0)
        XCTAssertNotNil(result.stats)
        XCTAssertEqual(result.stats?.filesScanned, 0)
        XCTAssertEqual(result.stats?.directoriesScanned, 0)
        XCTAssertEqual(result.stats?.errorCount, 0)
    }

    func testScanSingleFile() async {
        createFile(relativePath: "hello.txt", content: Data("hello world".utf8))

        let result = await collectEvents(rootPaths: [tempDir.path])

        XCTAssertEqual(result.files.count, 1)
        let record = result.files.first!
        XCTAssertEqual(record.name, "hello.txt")
        // The enumerator may resolve symlinks in the path (/var → /private/var).
        // Compare using hasSuffix which works regardless of symlink resolution.
        XCTAssertTrue(record.path.hasSuffix("hello.txt"))
        XCTAssertFalse(record.isDirectory)
        XCTAssertEqual(record.size, 11) // "hello world" = 11 bytes
        XCTAssertEqual(record.extension, "txt")
    }

    func testScanNestedDirectories() async {
        createFile(relativePath: "a/file1.txt")
        createFile(relativePath: "a/b/file2.txt")
        createFile(relativePath: "a/b/c/file3.txt")

        let result = await collectEvents(rootPaths: [tempDir.path])

        // 3 files at various nesting levels
        XCTAssertEqual(result.files.count, 3)
        let fileNames = Set(result.files.map(\.name))
        XCTAssertTrue(fileNames.contains("file1.txt"))
        XCTAssertTrue(fileNames.contains("file2.txt"))
        XCTAssertTrue(fileNames.contains("file3.txt"))

        // Directories: a, a/b, a/b/c
        XCTAssertEqual(result.directories.count, 3)
        let dirNames = Set(result.directories.map(\.name))
        XCTAssertTrue(dirNames.contains("a"))
        XCTAssertTrue(dirNames.contains("b"))
        XCTAssertTrue(dirNames.contains("c"))
    }

    func testSkipGitDirectory() async {
        createFile(relativePath: "src/main.swift")
        createFile(relativePath: "src/.git/objects/abc")
        createFile(relativePath: ".git/HEAD")

        var config = ScanConfiguration()
        config.skipPaths = ["/.git"]
        let result = await collectEvents(rootPaths: [tempDir.path], config: config)

        // main.swift found, .git contents skipped
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.name, "main.swift")
    }

    func testSkipNodeModules() async {
        createFile(relativePath: "package.json")
        createFile(relativePath: "node_modules/lodash/index.js")
        createFile(relativePath: "node_modules/react/index.js")

        var config = ScanConfiguration()
        config.skipPaths = ["/node_modules"]
        let result = await collectEvents(rootPaths: [tempDir.path], config: config)

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.name, "package.json")
    }

    func testSkipSystemDirectory() async {
        // Create a mock "System" dir inside temp to test skip logic
        createFile(relativePath: "System/Library/test.bin")
        createFile(relativePath: "good.txt")

        var config = ScanConfiguration()
        config.skipPaths = ["/System"]
        let result = await collectEvents(rootPaths: [tempDir.path], config: config)

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.name, "good.txt")
    }

    func testSkipPrivacyPaths() async {
        // Simulate privacy paths under temp directory
        createFile(relativePath: "Library/Caches/com.apple.test/cache.db")
        createFile(relativePath: "Library/Cookies/com.apple.test.cookies")
        createFile(relativePath: "Library/Keychains/test.keychain")
        createFile(relativePath: "normal.txt")

        var config = ScanConfiguration()
        config.privacySkipPaths = ["/Library/Caches", "/Library/Cookies", "/Library/Keychains"]
        let result = await collectEvents(rootPaths: [tempDir.path], config: config)

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.name, "normal.txt")
    }

    func testScanStats() async {
        createFile(relativePath: "file1.txt")
        createFile(relativePath: "file2.txt")
        createDirectory(relativePath: "subdir")

        let result = await collectEvents(rootPaths: [tempDir.path])

        XCTAssertNotNil(result.stats)
        XCTAssertEqual(result.stats?.filesScanned, 2)
        XCTAssertEqual(result.stats?.directoriesScanned, 1)
        XCTAssertGreaterThan(result.stats?.duration ?? 0, 0)
        XCTAssertEqual(result.stats?.errorCount, 0)
    }

    func testNFCNormalization() async {
        // "e" + combining acute accent (U+0301) → NFC should be "é" (U+00E9)
        let decomposed = "e\u{0301}xample.txt"
        let fileURL = tempDir.appendingPathComponent(decomposed)
        try! FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! Data("test".utf8).write(to: fileURL)

        let result = await collectEvents(rootPaths: [tempDir.path])

        XCTAssertEqual(result.files.count, 1)
        let record = result.files.first!
        // name should be NFC-normalized: "éxample.txt" (precomposed)
        let nfcExpected = "\u{00E9}xample.txt"
        XCTAssertEqual(record.name, nfcExpected)
        // originalName preserves the original decomposed form
        XCTAssertEqual(record.originalName, decomposed)
    }

    func testPermissionDeniedSkipped() async {
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
            // Restore permissions so tearDown can clean up
            try? FileManager.default.setAttributes(
                [.posixPermissions: Int16(0o755)],
                ofItemAtPath: restrictedDir.path
            )
        }

        let result = await collectEvents(rootPaths: [tempDir.path])

        // The restricted dir itself may or may not be found depending on enumeration
        // behavior, but inner file should NOT be found. Error count should be >= 1.
        let innerFound = result.files.contains { $0.name == "secret.txt" }
        XCTAssertFalse(innerFound, "Files in unreadable directories should not appear in results")
        XCTAssertGreaterThanOrEqual(result.stats?.errorCount ?? 0, 1)
        XCTAssertGreaterThanOrEqual(result.errors.count, 1)
    }

    func testFileRecordFieldsPopulated() async {
        let content = Data("Hello, World!".utf8) // 13 bytes
        createFile(relativePath: "docs/report.pdf", content: content)

        let result = await collectEvents(rootPaths: [tempDir.path])

        XCTAssertEqual(result.files.count, 1)
        let record = result.files.first!
        XCTAssertEqual(record.name, "report.pdf")
        XCTAssertEqual(record.originalName, "report.pdf")
        // The enumerator may resolve symlinks in the path (/var → /private/var).
        // Compare using hasSuffix which works regardless of symlink resolution.
        XCTAssertTrue(record.path.hasSuffix("docs/report.pdf"))
        XCTAssertFalse(record.isDirectory)
        XCTAssertEqual(record.size, 13)
        XCTAssertEqual(record.extension, "pdf")
        // ID should be assigned
        XCTAssertGreaterThan(record.id, 0)
        // Dates should be reasonable (not far in the past/future)
        let now = Date()
        XCTAssertLessThanOrEqual(record.createdAt, now)
        XCTAssertLessThanOrEqual(record.modifiedAt, now)
        // parentPath should point to the containing directory
        XCTAssertTrue(record.parentPath.hasSuffix("docs"))
    }

    func testSymlinkNotFollowed() async {
        let targetFile = createFile(relativePath: "real.txt")
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
        XCTAssertTrue(names.contains("real.txt"), "Real file should be found")
        // The symlink itself should not appear as a regular file when followSymlinks is false
        // (symlinks are skipped, not followed)
        // The key invariant: we don't traverse through the symlink
        XCTAssertEqual(result.files.count, 1, "Only the real file, not symlink target content")
    }

    func testProgressEventsEmitted() async {
        // Create several files to ensure progress events are generated
        for i in 0..<20 {
            createFile(relativePath: "file_\(i).txt", content: Data("x".utf8))
        }

        let result = await collectEvents(rootPaths: [tempDir.path])

        // Should have at least one progress event for 20 files
        XCTAssertGreaterThan(result.progressEvents.count, 0, "Progress events should be emitted during scan")
        // Progress should be monotonically non-decreasing
        for i in 1..<result.progressEvents.count {
            XCTAssertGreaterThanOrEqual(
                result.progressEvents[i],
                result.progressEvents[i - 1],
                "Progress counts should be non-decreasing"
            )
        }
    }
}
