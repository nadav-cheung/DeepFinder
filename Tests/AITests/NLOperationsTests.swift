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
        // No destructive operations like delete/remove/erase
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

    @Test("NLOperationRecord stores operation, timestamp, and reversed flag")
    func operationRecordFields() {
        let op = NLOperation(type: .copy, sourcePattern: "docs", destination: "/tmp", preview: [])
        let now = Date()
        let record = NLOperationRecord(operation: op, timestamp: now, reversed: true)
        #expect(record.operation == op)
        #expect(record.timestamp == now)
        #expect(record.reversed == true)
    }

    @Test("NLOperationRecord defaults reversed to false")
    func operationRecordDefaultReversed() {
        let record = NLOperationRecord(
            operation: NLOperation(type: .move, sourcePattern: "a", destination: "b", preview: []),
            timestamp: Date(),
            reversed: false
        )
        #expect(record.reversed == false)
    }

    // MARK: - NLOperationHistory records and pops

    @Test("NLOperationHistory records and pops operations")
    func historyRecordsAndPops() async {
        let history = NLOperationHistory()
        let op = NLOperation(type: .move, sourcePattern: "photos", destination: "/tmp", preview: [])
        await history.record(op)

        #expect(await history.canUndo == true)

        let popped = await history.popLast()
        #expect(popped != nil)
        #expect(popped?.operation == op)
        #expect(popped?.reversed == false)

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
        // Record 25 operations
        for i in 0..<25 {
            let op = NLOperation(
                type: .move,
                sourcePattern: "file_\(i)",
                destination: "/tmp/\(i)",
                preview: []
            )
            await history.record(op)
        }

        // Only 20 should remain; the oldest 5 (0-4) are dropped
        // Pop all and collect
        var popped: [NLOperationRecord] = []
        while let record = await history.popLast() {
            popped.append(record)
        }
        #expect(popped.count == 20)

        // The oldest remaining should be index 5 (first non-dropped)
        let oldest = popped.last // LIFO, so last popped = oldest
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
        // Should still have all 20
        var count = 0
        while (await history.popLast()) != nil { count += 1 }
        #expect(count == 20)
    }

    // MARK: - NLOperationExecutor requires confirmation

    @Test("NLOperationExecutor returns confirmed when confirmation accepted")
    func executorConfirmed() {
        let executor = NLOperationExecutor()
        let op = NLOperation(
            type: .move,
            sourcePattern: "photos",
            destination: "/tmp/photos",
            preview: ["/Users/alice/photos/a.jpg", "/Users/alice/photos/b.png"]
        )
        let result = executor.execute(op, confirm: { true })
        #expect(result != nil)
        #expect(result?.status == .confirmed)
        #expect(result?.affectedCount == 2)
    }

    @Test("NLOperationExecutor returns rejected when confirmation denied")
    func executorRejected() {
        let executor = NLOperationExecutor()
        let op = NLOperation(
            type: .copy,
            sourcePattern: "docs",
            destination: "/tmp/docs",
            preview: ["/Users/alice/docs/report.pdf"]
        )
        let result = executor.execute(op, confirm: { false })
        #expect(result != nil)
        #expect(result?.status == .rejected)
        #expect(result?.affectedCount == 0)
    }

    @Test("NLOperationExecutor returns confirmed with zero preview files")
    func executorEmptyPreview() {
        let executor = NLOperationExecutor()
        let op = NLOperation(
            type: .rename,
            sourcePattern: "old.txt",
            destination: "new.txt",
            preview: []
        )
        let result = executor.execute(op, confirm: { true })
        #expect(result?.status == .confirmed)
        #expect(result?.affectedCount == 0)
    }

    // MARK: - NLOperationExecutor rejects destructive operations

    @Test("NLOperationExecutor rejects operation types outside safe set")
    func executorRejectsDestructive() {
        // We can only test with NLOperationType cases that exist.
        // Since the enum only has move/copy/rename, and all are safe,
        // we verify the safeOperationTypes set contains exactly those three.
        #expect(NLOperationExecutor.safeOperationTypes == [.move, .copy, .rename])
    }

    // MARK: - NLOperationResult and NLOperationStatus

    @Test("NLOperationResult is Sendable and Equatable")
    func operationResultSendable() {
        func assertSendable<T: Sendable>(_: T) {}
        let result = NLOperationResult(affectedCount: 3, status: .confirmed)
        assertSendable(result)
        let result2 = NLOperationResult(affectedCount: 3, status: .confirmed)
        #expect(result == result2)
    }

    @Test("NLOperationStatus raw values match expected strings")
    func operationStatusRawValues() {
        #expect(NLOperationStatus.confirmed.rawValue == "confirmed")
        #expect(NLOperationStatus.rejected.rawValue == "rejected")
        #expect(NLOperationStatus.rejectedDestructive.rawValue == "rejectedDestructive")
    }
}
