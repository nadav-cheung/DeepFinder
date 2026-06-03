import Testing
import Foundation
@testable import DeepFinder

@Suite("SearchFilter")
struct SearchFilterTests {

    // MARK: - Helpers

    private func makeFile(
        id: UInt32 = 1,
        name: String = "test.txt",
        size: Int64 = 1024,
        isDirectory: Bool = false,
        ext: String? = "txt",
        modifiedAt: Date = Date(),
        createdAt: Date = Date()
    ) -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            originalName: name,
            path: "/Users/test/\(name)",
            parentPath: "/Users/test",
            isDirectory: isDirectory,
            size: size,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            extension: ext
        )
    }

    // MARK: - Size Filters

    @Test("sizeMin filter matches records with size >= threshold")
    func sizeMinFilterMatches() {
        let filter = SearchFilter.sizeMin(1_000)
        let matching = makeFile(size: 1_500)
        let tooSmall = makeFile(size: 500)
        let exact = makeFile(size: 1_000)

        #expect(filter.matches(matching))
        #expect(!filter.matches(tooSmall))
        #expect(filter.matches(exact))
    }

    @Test("sizeMax filter matches records with size <= threshold")
    func sizeMaxFilterMatches() {
        let filter = SearchFilter.sizeMax(1_000)
        let matching = makeFile(size: 500)
        let tooLarge = makeFile(size: 1_500)
        let exact = makeFile(size: 1_000)

        #expect(filter.matches(matching))
        #expect(!filter.matches(tooLarge))
        #expect(filter.matches(exact))
    }

    @Test("sizeRange filter matches records within closed range")
    func sizeRangeFilterMatches() {
        let filter = SearchFilter.sizeRange(100...1_000)
        let inRange = makeFile(size: 500)
        let tooSmall = makeFile(size: 50)
        let tooLarge = makeFile(size: 2_000)
        let lowerBound = makeFile(size: 100)
        let upperBound = makeFile(size: 1_000)

        #expect(filter.matches(inRange))
        #expect(!filter.matches(tooSmall))
        #expect(!filter.matches(tooLarge))
        #expect(filter.matches(lowerBound))
        #expect(filter.matches(upperBound))
    }

    // MARK: - parseSizeFilter

    @Test("parseSizeFilter '>1mb' returns sizeMin(1_048_576)")
    func parseSizeFilterGreaterThanMB() {
        let result = SearchFilter.parseSizeFilter(">1mb")
        #expect(result == .sizeMin(1_048_576))
    }

    @Test("parseSizeFilter '100kb..10mb' returns sizeRange")
    func parseSizeFilterRange() {
        let result = SearchFilter.parseSizeFilter("100kb..10mb")
        let expected = Int64(100 * 1024)...Int64(10 * 1024 * 1024)
        #expect(result == .sizeRange(expected))
    }

    @Test("parseSizeFilter invalid input returns nil")
    func parseSizeFilterInvalid() {
        #expect(SearchFilter.parseSizeFilter("") == nil)
        #expect(SearchFilter.parseSizeFilter("abc") == nil)
        #expect(SearchFilter.parseSizeFilter(">abc") == nil)
        #expect(SearchFilter.parseSizeFilter("10xb") == nil)
    }

    // MARK: - Date Filters

    @Test("dateModifiedAfter filter matches records modified after date")
    func dateModifiedAfterFilterMatches() {
        let refDate = Date(timeIntervalSince1970: 1_000_000)
        let filter = SearchFilter.dateModifiedAfter(refDate)

        let after = makeFile(modifiedAt: Date(timeIntervalSince1970: 1_000_001))
        let before = makeFile(modifiedAt: Date(timeIntervalSince1970: 999_999))

        #expect(filter.matches(after))
        #expect(!filter.matches(before))
    }

    @Test("dateModifiedBefore filter matches records modified before date")
    func dateModifiedBeforeFilterMatches() {
        let refDate = Date(timeIntervalSince1970: 1_000_000)
        let filter = SearchFilter.dateModifiedBefore(refDate)

        let before = makeFile(modifiedAt: Date(timeIntervalSince1970: 999_999))
        let after = makeFile(modifiedAt: Date(timeIntervalSince1970: 1_000_001))

        #expect(filter.matches(before))
        #expect(!filter.matches(after))
    }

    @Test("dateModifiedRange filter matches records in date range")
    func dateModifiedRangeFilterMatches() {
        let lower = Date(timeIntervalSince1970: 1_000_000)
        let upper = Date(timeIntervalSince1970: 2_000_000)
        let filter = SearchFilter.dateModifiedRange(lower..<upper)

        let inRange = makeFile(modifiedAt: Date(timeIntervalSince1970: 1_500_000))
        let tooEarly = makeFile(modifiedAt: Date(timeIntervalSince1970: 999_999))
        let tooLate = makeFile(modifiedAt: Date(timeIntervalSince1970: 2_000_000))
        let justBefore = makeFile(modifiedAt: Date(timeIntervalSince1970: 1_999_999.999))

        #expect(filter.matches(inRange))
        #expect(!filter.matches(tooEarly))
        #expect(!filter.matches(tooLate))
        #expect(filter.matches(justBefore))
    }

    // MARK: - parseDateFilter

    @Test("parseDateFilter 'today' returns after midnight today")
    func parseDateFilterToday() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let midnight = cal.startOfDay(for: now)

        let result = SearchFilter.parseDateFilter("today", referenceDate: now)
        #expect(result != nil)

        if case .dateModifiedAfter(let date) = result {
            #expect(date == midnight)
        } else {
            Issue.record("Expected dateModifiedAfter, got \(String(describing: result))")
        }
    }

    @Test("parseDateFilter 'thisweek' returns after first weekday of this week")
    func parseDateFilterThisWeek() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        // Find first weekday of the current week (respects locale)
        let weekday = cal.component(.weekday, from: now)
        // Sunday=1, Monday=2, ... Saturday=7
        let daysSinceStart = (weekday - cal.firstWeekday + 7) % 7
        let weekStart = cal.date(
            byAdding: .day,
            value: -daysSinceStart,
            to: cal.startOfDay(for: now)
        )!

        let result = SearchFilter.parseDateFilter("thisweek", referenceDate: now)
        #expect(result != nil)

        if case .dateModifiedAfter(let date) = result {
            #expect(date == weekStart)
        } else {
            Issue.record("Expected dateModifiedAfter, got \(String(describing: result))")
        }
    }

    @Test("parseDateFilter '2026-01-01..2026-03-31' returns date range")
    func parseDateFilterExplicitRange() {
        let cal = Calendar(identifier: .gregorian)
        let ref = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let result = SearchFilter.parseDateFilter("2026-01-01..2026-03-31", referenceDate: ref)
        #expect(result != nil)

        if case .dateModifiedRange(let range) = result {
            let jan1 = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
            let apr1 = cal.date(from: DateComponents(year: 2026, month: 4, day: 1))!
            #expect(range.lowerBound == jan1)
            #expect(range.upperBound == apr1)
        } else {
            Issue.record("Expected dateModifiedRange, got \(String(describing: result))")
        }
    }

    // MARK: - Extension / FileType Filters

    @Test("extensionFilter matches by extension")
    func extensionFilterMatches() {
        let filter = SearchFilter.extensionFilter(["txt", "md"])
        let txt = makeFile(name: "readme.txt", ext: "txt")
        let md = makeFile(name: "notes.md", ext: "md")
        let swift = makeFile(name: "main.swift", ext: "swift")
        let dir = makeFile(name: "folder", isDirectory: true, ext: nil)

        #expect(filter.matches(txt))
        #expect(filter.matches(md))
        #expect(!filter.matches(swift))
        #expect(!filter.matches(dir))
    }

    @Test("fileTypeGroup audio matches .mp3")
    func fileTypeGroupAudioMatches() {
        let filter = SearchFilter.fileType(.audio)
        let mp3 = makeFile(name: "song.mp3", ext: "mp3")
        let wav = makeFile(name: "track.wav", ext: "wav")
        let txt = makeFile(name: "notes.txt", ext: "txt")
        let dir = makeFile(name: "music", isDirectory: true, ext: nil)

        #expect(filter.matches(mp3))
        #expect(filter.matches(wav))
        #expect(!filter.matches(txt))
        #expect(!filter.matches(dir))
    }

    // MARK: - isFile / isDirectory

    @Test("isFile filter excludes directories")
    func isFileFilterMatches() {
        let filter = SearchFilter.isFile
        let file = makeFile(isDirectory: false)
        let dir = makeFile(isDirectory: true)

        #expect(filter.matches(file))
        #expect(!filter.matches(dir))
    }

    @Test("isDirectory filter excludes files")
    func isDirectoryFilterMatches() {
        let filter = SearchFilter.isDirectory
        let file = makeFile(isDirectory: false)
        let dir = makeFile(isDirectory: true)

        #expect(!filter.matches(file))
        #expect(filter.matches(dir))
    }

    // MARK: - Depth Filters

    @Test("maxDepth filter matches records with path component count <= threshold")
    func maxDepthFilterMatches() {
        let filter = SearchFilter.maxDepth(2)
        let shallow = FileRecord(
            id: 1, name: "a.txt", originalName: "a.txt",
            path: "/a.txt", parentPath: "/",
            isDirectory: false, size: 0,
            createdAt: Date(), modifiedAt: Date(), extension: "txt"
        )   // depth 1
        let atLimit = FileRecord(
            id: 2, name: "b.txt", originalName: "b.txt",
            path: "/usr/b.txt", parentPath: "/usr",
            isDirectory: false, size: 0,
            createdAt: Date(), modifiedAt: Date(), extension: "txt"
        )   // depth 2
        let tooDeep = FileRecord(
            id: 3, name: "c.txt", originalName: "c.txt",
            path: "/usr/local/c.txt", parentPath: "/usr/local",
            isDirectory: false, size: 0,
            createdAt: Date(), modifiedAt: Date(), extension: "txt"
        )   // depth 3

        #expect(filter.matches(shallow))
        #expect(filter.matches(atLimit))
        #expect(!filter.matches(tooDeep))
    }

    @Test("minDepth filter matches records with path component count >= threshold")
    func minDepthFilterMatches() {
        let filter = SearchFilter.minDepth(3)
        let tooShallow = FileRecord(
            id: 1, name: "a.txt", originalName: "a.txt",
            path: "/a.txt", parentPath: "/",
            isDirectory: false, size: 0,
            createdAt: Date(), modifiedAt: Date(), extension: "txt"
        )   // depth 1
        let atLimit = FileRecord(
            id: 2, name: "b.txt", originalName: "b.txt",
            path: "/usr/local/bin", parentPath: "/usr/local",
            isDirectory: false, size: 0,
            createdAt: Date(), modifiedAt: Date(), extension: "txt"
        )   // depth 3  -- wait, path is "/usr/local/bin" which is 3 components
        // Actually the name is appended: path="/usr/local/bin" -> depth 3
        let deeper = FileRecord(
            id: 3, name: "c.txt", originalName: "c.txt",
            path: "/usr/local/bin/c.txt", parentPath: "/usr/local/bin",
            isDirectory: false, size: 0,
            createdAt: Date(), modifiedAt: Date(), extension: "txt"
        )   // depth 4

        #expect(!filter.matches(tooShallow))
        #expect(filter.matches(atLimit))
        #expect(filter.matches(deeper))
    }

    // MARK: - Filename Length Filters (REQ-1.5-05)

    @Test("nameLengthMin filter matches records with name length >= threshold")
    func nameLengthMinFilterMatches() {
        let filter = SearchFilter.nameLengthMin(5)
        let matching = makeFile(name: "hello.txt")    // "hello.txt" = 9 scalars
        let tooShort = makeFile(name: "ab")            // 2 scalars
        let exact = makeFile(name: "abcde")            // 5 scalars

        #expect(filter.matches(matching))
        #expect(!filter.matches(tooShort))
        #expect(filter.matches(exact))
    }

    @Test("nameLengthMax filter matches records with name length <= threshold")
    func nameLengthMaxFilterMatches() {
        let filter = SearchFilter.nameLengthMax(5)
        let matching = makeFile(name: "hi")            // 2 scalars
        let tooLong = makeFile(name: "hello world")    // 11 scalars
        let exact = makeFile(name: "abcde")             // 5 scalars

        #expect(filter.matches(matching))
        #expect(!filter.matches(tooLong))
        #expect(filter.matches(exact))
    }

    @Test("nameLengthRange filter matches records with name length in range")
    func nameLengthRangeFilterMatches() {
        let filter = SearchFilter.nameLengthRange(3...6)
        let inRange = makeFile(name: "test")            // 4 scalars
        let tooShort = makeFile(name: "ab")             // 2 scalars
        let tooLong = makeFile(name: "abcdefgh")        // 8 scalars
        let lowerBound = makeFile(name: "abc")          // 3 scalars
        let upperBound = makeFile(name: "abcdef")       // 6 scalars

        #expect(filter.matches(inRange))
        #expect(!filter.matches(tooShort))
        #expect(!filter.matches(tooLong))
        #expect(filter.matches(lowerBound))
        #expect(filter.matches(upperBound))
    }

    @Test("nameLength uses Unicode scalar count, not byte count")
    func nameLengthUnicodeScalarCount() {
        let filter = SearchFilter.nameLengthMin(3)
        // "café" = 4 Unicode scalars (c, a, f, é)
        let withAccent = makeFile(name: "café", ext: nil)
        #expect(filter.matches(withAccent))

        // "🎉" = 1 Unicode scalar
        let emoji = makeFile(name: "🎉", ext: nil)
        #expect(!filter.matches(emoji))
    }
}
