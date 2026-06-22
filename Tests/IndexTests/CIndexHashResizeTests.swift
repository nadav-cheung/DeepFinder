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

    @Test("path_remove preserves collision chain (backshift deletion)")
    func pathRemoveKeepsCollisionChainIntact() async {
        // Reproduces a real path-hash deletion bug. The first three paths share
        // home bucket 0 (verified via CIndex's own FNV-1a), forming a probe chain
        // at slots 0/1/2. The fourth path lives in a different bucket (10) and is
        // inserted LAST, so it is the record swapped into the freed slot on
        // removal. Removing the middle of the bucket-0 chain leaves a gap; the
        // swapped record (bucket 10) does not fill it, so without backshift
        // deletion the third bucket-0 path — which probed past the gap — becomes
        // unfindable. (A direct C probe against CIndex.c confirms `remove 30_x`
        // returns 0 on the unfixed code.)
        let chain = ["/chain/1_x", "/chain/27_x", "/chain/30_x"]  // all bucket 0
        let other = "/chain/3_x"                                   // bucket 10, last

        let index = InMemoryIndex(pathHashCap: 16)
        for p in chain {
            let name = (p as NSString).lastPathComponent
            await index.insert(
                name: name, path: p, parentPath: "/chain",
                isDirectory: false, extension: "txt"
            )
        }
        await index.insert(
            name: "3_x", path: other, parentPath: "/chain",
            isDirectory: false, extension: "txt"
        )

        // Remove the middle of the bucket-0 chain.
        #expect(await index.removeByPath(chain[1]) == true)

        // chain[2] probed past the freed slot — it must still be findable.
        let thirdSurvives = await index.removeByPath(chain[2])
        #expect(thirdSurvives == true, "chain[2] must survive deletion of chain[1]")

        #expect(await index.removeByPath(chain[0]) == true)
        #expect(await index.removeByPath(other) == true)
        #expect(await index.totalRecords == 0)
    }
}
