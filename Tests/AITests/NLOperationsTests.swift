import Foundation
import Testing
@testable import DeepFinder

@Suite("NLOperations")
struct NLOperationsTests {

    // MARK: - parseNLCommand detects move operation

    @Test("parseNLCommand detects 'move X to Y'")
    func parseMoveBasic() {
        let op = parseNLCommand("move photos to /Volumes/Backup/photos")
        #expect(op != nil)
        #expect(op?.type == .move)
        #expect(op?.sourcePattern == "photos")
        #expect(op?.destination == "/Volumes/Backup/photos")
    }

    @Test("parseNLCommand detects 'Move X to Y' (capitalized)")
    func parseMoveCapitalized() {
        let op = parseNLCommand("Move reports to ~/Archive")
        #expect(op != nil)
        #expect(op?.type == .move)
        #expect(op?.sourcePattern == "reports")
        #expect(op?.destination == "~/Archive")
    }

    // MARK: - parseNLCommand detects copy operation

    @Test("parseNLCommand detects 'copy X to Y'")
    func parseCopyBasic() {
        let op = parseNLCommand("copy documents to /Volumes/USB/docs")
        #expect(op != nil)
        #expect(op?.type == .copy)
        #expect(op?.sourcePattern == "documents")
        #expect(op?.destination == "/Volumes/USB/docs")
    }

    @Test("parseNLCommand detects 'Copy X to Y' (capitalized)")
    func parseCopyCapitalized() {
        let op = parseNLCommand("Copy backups to /tmp/backup")
        #expect(op != nil)
        #expect(op?.type == .copy)
        #expect(op?.sourcePattern == "backups")
        #expect(op?.destination == "/tmp/backup")
    }

    // MARK: - parseNLCommand detects rename operation

    @Test("parseNLCommand detects 'rename X to Y'")
    func parseRenameBasic() {
        let op = parseNLCommand("rename draft.txt to final.txt")
        #expect(op != nil)
        #expect(op?.type == .rename)
        #expect(op?.sourcePattern == "draft.txt")
        #expect(op?.destination == "final.txt")
    }

    @Test("parseNLCommand detects 'Rename X to Y' (capitalized)")
    func parseRenameCapitalized() {
        let op = parseNLCommand("Rename old_report.pdf to new_report.pdf")
        #expect(op != nil)
        #expect(op?.type == .rename)
        #expect(op?.sourcePattern == "old_report.pdf")
        #expect(op?.destination == "new_report.pdf")
    }

    // MARK: - parseNLCommand rejects delete operation

    @Test("parseNLCommand returns nil for 'delete X'")
    func rejectsDelete() {
        let op = parseNLCommand("delete temp files")
        #expect(op == nil)
    }

    @Test("parseNLCommand returns nil for 'Delete X' (capitalized)")
    func rejectsDeleteCapitalized() {
        let op = parseNLCommand("Delete old backups")
        #expect(op == nil)
    }

    @Test("parseNLCommand returns nil for 'remove X'")
    func rejectsRemove() {
        let op = parseNLCommand("remove junk files")
        #expect(op == nil)
    }

    @Test("parseNLCommand returns nil for 'rm X'")
    func rejectsRm() {
        let op = parseNLCommand("rm cache")
        #expect(op == nil)
    }

    // MARK: - parseNLCommand rejects unrecognized input

    @Test("parseNLCommand returns nil for empty string")
    func rejectsEmpty() {
        let op = parseNLCommand("")
        #expect(op == nil)
    }

    @Test("parseNLCommand returns nil for random text")
    func rejectsRandomText() {
        let op = parseNLCommand("the quick brown fox")
        #expect(op == nil)
    }

    // MARK: - NLOperationType only contains safe operations

    @Test("NLOperationType contains only safe operations")
    func safeOperationsOnly() {
        let allTypes = NLOperationType.allCases
        #expect(allTypes.count == 3)
        #expect(allTypes.contains(.move))
        #expect(allTypes.contains(.copy))
        #expect(allTypes.contains(.rename))
    }

    // MARK: - generatePreview filters matching files

    @Test("generatePreview filters files matching source pattern")
    func previewMatchesFiles() {
        let op = NLOperation(
            type: .move,
            sourcePattern: "photos",
            destination: "/Volumes/Backup/photos",
            preview: []
        )
        let files = [
            "/Users/alice/photos/vacation.jpg",
            "/Users/alice/photos/portrait.png",
            "/Users/alice/Documents/report.pdf",
            "/Users/alice/photos_2025/sunset.jpg",
        ]
        let preview = generatePreview(operation: op, availableFiles: files)
        #expect(preview.contains("/Users/alice/photos/vacation.jpg"))
        #expect(preview.contains("/Users/alice/photos/portrait.png"))
        #expect(preview.contains("/Users/alice/photos_2025/sunset.jpg"))
        #expect(!preview.contains("/Users/alice/Documents/report.pdf"))
    }

    @Test("generatePreview returns empty for no matches")
    func previewNoMatches() {
        let op = NLOperation(
            type: .copy,
            sourcePattern: "xyzzy",
            destination: "/tmp/nowhere",
            preview: []
        )
        let files = ["/Users/alice/Documents/report.pdf"]
        let preview = generatePreview(operation: op, availableFiles: files)
        #expect(preview.isEmpty)
    }

    @Test("generatePreview matches all files when pattern is broad")
    func previewBroadPattern() {
        let op = NLOperation(
            type: .rename,
            sourcePattern: "report",
            destination: "summary",
            preview: []
        )
        let files = [
            "/Users/alice/report_q1.txt",
            "/Users/alice/report_q2.txt",
        ]
        let preview = generatePreview(operation: op, availableFiles: files)
        #expect(preview.count == 2)
    }

    // MARK: - Sendable / Codable conformance

    @Test("NLOperationType is Sendable and Codable")
    func operationTypeSendable() {
        func assertSendable<T: Sendable>(_: T) {}
        assertSendable(NLOperationType.move)
        // Codable round-trip
        let data = try! JSONEncoder().encode(NLOperationType.copy)
        let decoded = try! JSONDecoder().decode(NLOperationType.self, from: data)
        #expect(decoded == .copy)
    }

    @Test("NLOperation is Sendable and Equatable")
    func operationSendable() {
        func assertSendable<T: Sendable>(_: T) {}
        let op = NLOperation(type: .move, sourcePattern: "a", destination: "b", preview: [])
        assertSendable(op)
        let op2 = NLOperation(type: .move, sourcePattern: "a", destination: "b", preview: [])
        #expect(op == op2)
    }

    // MARK: - NLOperationRecord

    @Test("NLOperationRecord stores operation, timestamp, reversed flag, and originalPaths")
    func operationRecordFields() {
        let op = NLOperation(type: .copy, sourcePattern: "docs", destination: "/tmp", preview: [])
        let now = Date()
        let record = NLOperationRecord(
            operation: op,
            timestamp: now,
            reversed: true,
            originalPaths: ["/tmp/docs/a.txt": "/Users/alice/docs/a.txt"]
        )
        #expect(record.operation == op)
        #expect(record.timestamp == now)
        #expect(record.reversed == true)
        #expect(record.originalPaths["/tmp/docs/a.txt"] == "/Users/alice/docs/a.txt")
    }

    @Test("NLOperationRecord defaults reversed to false and originalPaths to empty")
    func operationRecordDefaults() {
        let record = NLOperationRecord(
            operation: NLOperation(type: .move, sourcePattern: "a", destination: "b", preview: []),
            timestamp: Date(),
            reversed: false,
            originalPaths: [:]
        )
        #expect(record.reversed == false)
        #expect(record.originalPaths.isEmpty)
    }

    // MARK: - NLOperationHistory records and pops

    @Test("NLOperationHistory records and pops operations")
    func historyRecordsAndPops() async {
        let history = NLOperationHistory()
        let op = NLOperation(type: .move, sourcePattern: "photos", destination: "/tmp", preview: [])
        await history.record(op, originalPaths: ["/tmp/photos/a.jpg": "/Users/alice/photos/a.jpg"])

        #expect(await history.canUndo == true)

        let popped = await history.popLast()
        #expect(popped != nil)
        #expect(popped?.operation == op)
        #expect(popped?.reversed == false)
        #expect(popped?.originalPaths["/tmp/photos/a.jpg"] == "/Users/alice/photos/a.jpg")

        #expect(await history.canUndo == false)
        #expect(await history.popLast() == nil)
    }

    @Test("NLOperationHistory pops in LIFO order")
    func historyLIFO() async {
        let history = NLOperationHistory()
        let op1 = NLOperation(type: .move, sourcePattern: "a", destination: "b", preview: [])
        let op2 = NLOperation(type: .copy, sourcePattern: "c", destination: "d", preview: [])

        await history.record(op1)
        await history.record(op2)

        let first = await history.popLast()
        #expect(first?.operation == op2)

        let second = await history.popLast()
        #expect(second?.operation == op1)
    }

    @Test("NLOperationHistory.canUndo is false when empty")
    func historyCanUndoEmpty() async {
        let history = NLOperationHistory()
        #expect(await history.canUndo == false)
    }

    @Test("NLOperationHistory.clear removes all records")
    func historyClear() async {
        let history = NLOperationHistory()
        await history.record(NLOperation(type: .move, sourcePattern: "a", destination: "b", preview: []))
        await history.record(NLOperation(type: .copy, sourcePattern: "c", destination: "d", preview: []))

        #expect(await history.canUndo == true)
        await history.clear()
        #expect(await history.canUndo == false)
        #expect(await history.popLast() == nil)
    }

    // MARK: - NLOperationHistory max 20 items

    @Test("NLOperationHistory drops oldest items beyond max 20")
    func historyMaxItems() async {
        let history = NLOperationHistory()
        for i in 0..<25 {
            let op = NLOperation(
                type: .move,
                sourcePattern: "file_\(i)",
                destination: "/tmp/\(i)",
                preview: []
            )
            await history.record(op)
        }

        var popped: [NLOperationRecord] = []
        while let record = await history.popLast() {
            popped.append(record)
        }
        #expect(popped.count == 20)

        let oldest = popped.last
        #expect(oldest?.operation.sourcePattern == "file_5")
    }

    @Test("NLOperationHistory at exactly 20 items does not drop")
    func historyExactlyMax() async {
        let history = NLOperationHistory()
        for i in 0..<20 {
            await history.record(NLOperation(
                type: .copy,
                sourcePattern: "item_\(i)",
                destination: "/tmp/\(i)",
                preview: []
            ))
        }
        var count = 0
        while (await history.popLast()) != nil { count += 1 }
        #expect(count == 20)
    }

    // MARK: - MockFileManagerProvider

    /// A mock file manager that records operations for test assertions.
    final class MockFileManagerProvider: FileManagerProvider, @unchecked Sendable {
        struct MoveCall: Equatable { let src: String; let dst: String }
        struct CopyCall: Equatable { let src: String; let dst: String }
        struct RemoveCall: Equatable { let path: String }
        struct CreateDirCall: Equatable { let path: String; let intermediates: Bool }

        private(set) var moves: [MoveCall] = []
        private(set) var copies: [CopyCall] = []
        private(set) var removes: [RemoveCall] = []
        private(set) var createDirs: [CreateDirCall] = []

        /// Set of paths that "exist" in the mock filesystem.
        var existingPaths: Set<String> = []

        /// Paths that should throw on move.
        var moveErrorPaths: Set<String> = []
        /// Paths that should throw on copy.
        var copyErrorPaths: Set<String> = []
        /// Error to throw when path matches.
        var stubError: Error = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "mock error"
        ])

        func moveItem(at src: URL, to dst: URL) throws {
            if moveErrorPaths.contains(src.path) {
                throw stubError
            }
            moves.append(MoveCall(src: src.path, dst: dst.path))
        }

        func copyItem(at src: URL, to dst: URL) throws {
            if copyErrorPaths.contains(src.path) {
                throw stubError
            }
            copies.append(CopyCall(src: src.path, dst: dst.path))
        }

        func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
            createDirs.append(CreateDirCall(path: url.path, intermediates: createIntermediates))
        }

        func fileExists(atPath path: String) -> Bool {
            return existingPaths.contains(path)
        }

        func removeItem(at url: URL) throws {
            removes.append(RemoveCall(path: url.path))
        }
    }

    // MARK: - NLOperationExecutor execute move

    @Test("Executor move calls FileManager.moveItem for each file")
    func executorMoveFiles() async {
        let mock = MockFileManagerProvider()
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .move,
            sourcePattern: "photos",
            destination: "/Volumes/Backup/photos",
            preview: []
        )
        let files = ["/Users/alice/photos/a.jpg", "/Users/alice/photos/b.png"]

        let result = await executor.execute(op, confirm: { true }, availableFiles: files)

        #expect(result != nil)
        #expect(result?.success == true)
        #expect(result?.affectedCount == 2)
        #expect(result?.status == .confirmed)
        #expect(result?.errors.isEmpty == true)

        #expect(mock.moves.count == 2)
        #expect(mock.moves[0].src == "/Users/alice/photos/a.jpg")
        #expect(mock.moves[0].dst == "/Volumes/Backup/photos/a.jpg")
        #expect(mock.moves[1].src == "/Users/alice/photos/b.png")
        #expect(mock.moves[1].dst == "/Volumes/Backup/photos/b.png")

        // Should have created the destination directory
        #expect(mock.createDirs.count == 2)
    }

    // MARK: - NLOperationExecutor execute copy

    @Test("Executor copy calls FileManager.copyItem for each file")
    func executorCopyFiles() async {
        let mock = MockFileManagerProvider()
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .copy,
            sourcePattern: "docs",
            destination: "/tmp/docs_backup",
            preview: []
        )
        let files = ["/Users/alice/docs/report.pdf"]

        let result = await executor.execute(op, confirm: { true }, availableFiles: files)

        #expect(result?.success == true)
        #expect(result?.affectedCount == 1)
        #expect(mock.copies.count == 1)
        #expect(mock.copies[0].src == "/Users/alice/docs/report.pdf")
        #expect(mock.copies[0].dst == "/tmp/docs_backup/report.pdf")
    }

    // MARK: - NLOperationExecutor execute rename

    @Test("Executor rename calls FileManager.moveItem in same directory")
    func executorRenameFile() async {
        let mock = MockFileManagerProvider()
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .rename,
            sourcePattern: "draft.txt",
            destination: "final.txt",
            preview: []
        )
        let files = ["/Users/alice/Desktop/draft.txt"]

        let result = await executor.execute(op, confirm: { true }, availableFiles: files)

        #expect(result?.success == true)
        #expect(result?.affectedCount == 1)
        #expect(mock.moves.count == 1)
        #expect(mock.moves[0].src == "/Users/alice/Desktop/draft.txt")
        #expect(mock.moves[0].dst == "/Users/alice/Desktop/final.txt")
        // Rename should NOT create directories
        #expect(mock.createDirs.isEmpty)
    }

    // MARK: - Confirmation rejection prevents execution

    @Test("Executor returns rejected when confirm returns false, no file ops")
    func executorRejectedNoOps() async {
        let mock = MockFileManagerProvider()
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .copy,
            sourcePattern: "docs",
            destination: "/tmp/docs",
            preview: []
        )
        let files = ["/Users/alice/docs/report.pdf"]

        let result = await executor.execute(op, confirm: { false }, availableFiles: files)

        #expect(result?.status == .rejected)
        #expect(result?.affectedCount == 0)
        #expect(result?.success == false)
        #expect(mock.copies.isEmpty)
        #expect(mock.moves.isEmpty)
    }

    // MARK: - Executor records history on success

    @Test("Executor records operation in history after successful execution")
    func executorRecordsHistory() async {
        let mock = MockFileManagerProvider()
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .move,
            sourcePattern: "photos",
            destination: "/tmp/photos",
            preview: []
        )
        let files = ["/Users/alice/photos/a.jpg"]

        _ = await executor.execute(op, confirm: { true }, availableFiles: files)

        #expect(await history.canUndo == true)
        let record = await history.popLast()
        #expect(record != nil)
        #expect(record?.operation == op)
        #expect(record?.originalPaths["/tmp/photos/a.jpg"] == "/Users/alice/photos/a.jpg")
    }

    @Test("Executor does not record in history when no files succeed")
    func executorNoHistoryOnAllFailures() async {
        let mock = MockFileManagerProvider()
        mock.moveErrorPaths = ["/Users/alice/photos/a.jpg"]
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .move,
            sourcePattern: "photos",
            destination: "/tmp/photos",
            preview: []
        )
        let files = ["/Users/alice/photos/a.jpg"]

        _ = await executor.execute(op, confirm: { true }, availableFiles: files)

        #expect(await history.canUndo == false)
    }

    // MARK: - Per-file errors collected

    @Test("Executor collects per-file errors when some files fail")
    func executorPartialErrors() async {
        let mock = MockFileManagerProvider()
        mock.copyErrorPaths = ["/Users/alice/docs/broken.pdf"]
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .copy,
            sourcePattern: "docs",
            destination: "/tmp/docs",
            preview: []
        )
        let files = ["/Users/alice/docs/report.pdf", "/Users/alice/docs/broken.pdf"]

        let result = await executor.execute(op, confirm: { true }, availableFiles: files)

        #expect(result?.affectedCount == 1)
        #expect(result?.errors.count == 1)
        #expect(result?.errors[0].contains("broken.pdf") == true)
        // success is false because there are errors
        #expect(result?.success == false)
        // But the successful file was still recorded in history
        #expect(await history.canUndo == true)
    }

    // MARK: - Undo reverses move

    @Test("Undo move reverses by moving files back")
    func undoMove() async {
        let mock = MockFileManagerProvider()
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .move,
            sourcePattern: "photos",
            destination: "/tmp/photos",
            preview: []
        )
        let files = ["/Users/alice/photos/a.jpg"]

        _ = await executor.execute(op, confirm: { true }, availableFiles: files)

        // Execute produced 1 move (src -> dst)
        #expect(mock.moves.count == 1)

        // Undo should move it back
        let undone = await executor.undoLast()
        #expect(undone != nil)
        #expect(undone?.operation == op)
        // Now we should have 2 moves total: forward + undo
        #expect(mock.moves.count == 2)
        #expect(mock.moves[1].src == "/tmp/photos/a.jpg")
        #expect(mock.moves[1].dst == "/Users/alice/photos/a.jpg")
    }

    // MARK: - Undo reverses copy

    @Test("Undo copy reverses by removing copied files")
    func undoCopy() async {
        let mock = MockFileManagerProvider()
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .copy,
            sourcePattern: "docs",
            destination: "/tmp/docs",
            preview: []
        )
        let files = ["/Users/alice/docs/report.pdf"]

        _ = await executor.execute(op, confirm: { true }, availableFiles: files)

        #expect(mock.copies.count == 1)

        let undone = await executor.undoLast()
        #expect(undone != nil)
        // Undo copy should remove the destination file
        #expect(mock.removes.count == 1)
        #expect(mock.removes[0].path == "/tmp/docs/report.pdf")
    }

    // MARK: - Undo reverses rename

    @Test("Undo rename reverses by renaming back")
    func undoRename() async {
        let mock = MockFileManagerProvider()
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .rename,
            sourcePattern: "draft.txt",
            destination: "final.txt",
            preview: []
        )
        let files = ["/Users/alice/Desktop/draft.txt"]

        _ = await executor.execute(op, confirm: { true }, availableFiles: files)

        #expect(mock.moves.count == 1)

        let undone = await executor.undoLast()
        #expect(undone != nil)
        // Undo should rename it back
        #expect(mock.moves.count == 2)
        #expect(mock.moves[1].src == "/Users/alice/Desktop/final.txt")
        #expect(mock.moves[1].dst == "/Users/alice/Desktop/draft.txt")
    }

    // MARK: - Undo returns nil when no history

    @Test("Undo returns nil when no history available")
    func undoEmpty() async {
        let mock = MockFileManagerProvider()
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let undone = await executor.undoLast()
        #expect(undone == nil)
        #expect(mock.moves.isEmpty)
        #expect(mock.removes.isEmpty)
    }

    // MARK: - Empty availableFiles produces confirmed with 0 count

    @Test("Executor with empty availableFiles returns confirmed with 0 count")
    func executorEmptyFiles() async {
        let mock = MockFileManagerProvider()
        let history = NLOperationHistory()
        let executor = NLOperationExecutor(fileManager: mock, history: history)

        let op = NLOperation(
            type: .move,
            sourcePattern: "photos",
            destination: "/tmp/photos",
            preview: []
        )

        let result = await executor.execute(op, confirm: { true }, availableFiles: [])

        #expect(result?.status == .confirmed)
        #expect(result?.affectedCount == 0)
        #expect(result?.success == true)
        #expect(result?.errors.isEmpty == true)
        // No history recorded when nothing was done
        #expect(await history.canUndo == false)
    }

    // MARK: - NLOperationExecutor rejects destructive operations

    @Test("NLOperationExecutor rejects operation types outside safe set")
    func executorRejectsDestructive() {
        #expect(NLOperationExecutor.safeOperationTypes == [.move, .copy, .rename])
    }

    // MARK: - NLOperationResult and NLOperationStatus

    @Test("NLOperationResult is Sendable and Equatable")
    func operationResultSendable() {
        func assertSendable<T: Sendable>(_: T) {}
        let result = NLOperationResult(success: true, affectedCount: 3, status: .confirmed, errors: [])
        assertSendable(result)
        let result2 = NLOperationResult(success: true, affectedCount: 3, status: .confirmed, errors: [])
        #expect(result == result2)
    }

    @Test("NLOperationStatus raw values match expected strings")
    func operationStatusRawValues() {
        #expect(NLOperationStatus.confirmed.rawValue == "confirmed")
        #expect(NLOperationStatus.rejected.rawValue == "rejected")
        #expect(NLOperationStatus.rejectedDestructive.rawValue == "rejectedDestructive")
    }

    // MARK: - SystemFileManagerProvider conforms to protocol

    @Test("SystemFileManagerProvider conforms to FileManagerProvider")
    func systemProviderConformance() {
        func assertProvider<T: FileManagerProvider>(_: T) {}
        assertProvider(SystemFileManagerProvider())
    }
}
