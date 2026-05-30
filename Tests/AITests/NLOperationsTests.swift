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
}
