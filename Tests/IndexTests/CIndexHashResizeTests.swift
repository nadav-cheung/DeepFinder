import Testing
import Foundation
@testable import DeepFinderIndex

@Suite("CIndex path hash")
struct CIndexHashResizeTests {

    @Test("Small-cap constructor builds a working index")
    func smallCapConstructorWorks() async {
        let index = InMemoryIndex(pathHashCap: 16)
        await index.insert(
            name: "hello.txt",
            path: "/tmp/hello.txt",
            parentPath: "/tmp",
            isDirectory: false,
            extension: "txt"
        )
        let results = await index.searchSubstring(query: "hello")
        #expect(results.count == 1)
        #expect(results.first?.path == "/tmp/hello.txt")
    }

    @Test("Path hash resizes past capacity without hang or loss")
    func pathHashResizesBeyondCapacity() async {
        let index = InMemoryIndex(pathHashCap: 16)

        // Insert 200 unique paths. Load factor crosses 0.5 at 9 entries, so the
        // 16-slot table must resize repeatedly (16→32→64→128→256). Under the
        // unfixed code the table fills at 16 entries and the 17th insert hangs
        // (probe loop wraps forever) — that hang IS the bug.
        for i in 0..<200 {
            await index.insert(
                name: "file_\(i).txt",
                path: "/tmp/resize/\(i)/file_\(i).txt",
                parentPath: "/tmp/resize/\(i)",
                isDirectory: false,
                extension: "txt"
            )
        }
        let total = await index.totalRecords
        #expect(total == 200, "all 200 records must survive resize")

        // Upsert an existing path: path_lookup must still find it post-resize,
        // updating in place rather than duplicating.
        await index.insert(
            name: "file_0.txt",
            path: "/tmp/resize/0/file_0.txt",
            parentPath: "/tmp/resize/0",
            isDirectory: false,
            size: 999,
            extension: "txt"
        )
        #expect(await index.totalRecords == 200, "upsert must not duplicate")

        // Remove by path: path_remove must still work post-resize.
        let removed = await index.removeByPath("/tmp/resize/1/file_1.txt")
        #expect(removed == true)
        #expect(await index.totalRecords == 199)
    }
}
