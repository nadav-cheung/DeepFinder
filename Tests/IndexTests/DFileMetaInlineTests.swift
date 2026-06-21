// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Testing
import Foundation
@testable import DeepFinderIndex

/// Guards the P1 single-allocation `DFileMeta` refactor. Because per-record
/// strings move from separate `strdup` allocations into one inline flexible-array
/// blob, multibyte names (CJK, emoji, combining marks) are the case most likely
/// to break if byte offsets / NUL placement are mishandled. These tests go
/// through the public `InMemoryIndex` API so they apply to whatever storage
/// backs it.
@Suite("DFileMeta inline string storage")
struct DFileMetaInlineTests {

    @Test("Multibyte names (CJK, emoji, combining) round-trip intact")
    func multibyteRoundTrip() async {
        let index = InMemoryIndex()
        let cases: [(name: String, path: String)] = [
            ("报告.txt", "/d/报告.txt"),
            ("👾 emoji.md", "/d/👾 emoji.md"),
            ("café.pdf", "/d/café.pdf"),
            ("データ.bin", "/d/データ.bin"),
        ]
        for c in cases {
            await index.insert(
                name: c.name, path: c.path, parentPath: "/d",
                isDirectory: false, extension: nil
            )
        }

        // allRecords preserves every multibyte name + path byte-for-byte.
        let records = await index.allRecords()
        for c in cases {
            #expect(records.contains { $0.path == c.path && $0.name == c.name },
                    "missing/not intact: \(c.name) @ \(c.path)")
        }

        // Substring search over a CJK fragment must still hit (trigram path).
        let hits = await index.searchSubstring(query: "报告")
        #expect(hits.count == 1)
        #expect(hits.first?.path == "/d/报告.txt")
    }

    @Test("Upsert replaces inline storage without leaking the old name")
    func upsertReplacesInlineStorage() async {
        let index = InMemoryIndex()
        await index.insert(name: "old.txt", path: "/u/file.txt", parentPath: "/u",
                           isDirectory: false, size: 10, extension: "txt")
        // Same path → upsert: old DFileMeta freed, new one created.
        await index.insert(name: "new.txt", path: "/u/file.txt", parentPath: "/u",
                           isDirectory: false, size: 99, extension: "txt")

        #expect(await index.totalRecords == 1, "upsert must not duplicate")
        let rec = await index.allRecords()
        #expect(rec.count == 1)
        #expect(rec.first?.name == "new.txt")
        #expect(rec.first?.size == 99)
        // Old name must no longer be searchable.
        #expect(await index.search(query: "old").count == 0)
        #expect(await index.search(query: "new").count == 1)
    }
}
