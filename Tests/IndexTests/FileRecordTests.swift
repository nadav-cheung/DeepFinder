import Foundation
import Testing
@testable import DeepFinder

@Suite("FileRecord")
struct FileRecordTests {

    private func makeRecord(
        id: UInt32 = 1,
        name: String = "report.pdf",
        path: String = "/Users/test/Documents/report.pdf",
        parentPath: String = "/Users/test/Documents",
        isDirectory: Bool = false,
        size: Int64 = 1024,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
        extension ext: String? = "pdf"
    ) -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            originalName: name,
            path: path,
            parentPath: parentPath,
            isDirectory: isDirectory,
            size: size,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            extension: ext
        )
    }

    @Test("属性访问")
    func propertyAccess() {
        let record = makeRecord()
        #expect(record.id == 1)
        #expect(record.name == "report.pdf")
        #expect(record.originalName == "report.pdf")
        #expect(record.path == "/Users/test/Documents/report.pdf")
        #expect(record.parentPath == "/Users/test/Documents")
        #expect(record.isDirectory == false)
        #expect(record.size == 1024)
        #expect(record.extension == "pdf")
    }

    @Test("目录的 extension 为 nil")
    func directoryExtensionNil() {
        let record = makeRecord(
            name: "Documents",
            path: "/Users/test/Documents",
            parentPath: "/Users/test",
            isDirectory: true,
            size: 0,
            extension: nil
        )
        #expect(record.isDirectory == true)
        #expect(record.extension == nil)
    }

    @Test("Codable 往返序列化")
    func codableRoundTrip() throws {
        let original = makeRecord()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileRecord.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.originalName == original.originalName)
        #expect(decoded.path == original.path)
        #expect(decoded.parentPath == original.parentPath)
        #expect(decoded.isDirectory == original.isDirectory)
        #expect(decoded.size == original.size)
        #expect(decoded.extension == original.extension)
    }

    @Test("NFC 统一化 — ASCII 不变")
    func nfcAsciiUnchanged() {
        let record = makeRecord(name: "hello.txt", extension: "txt")
        #expect(record.name == "hello.txt")
    }

    @Test("日期字段 Codable 精度")
    func dateCodablePrecision() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000.123)
        let record = makeRecord(createdAt: created, modifiedAt: created)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(FileRecord.self, from: data)
        #expect(decoded.createdAt == created)
        #expect(decoded.modifiedAt == created)
    }
}
