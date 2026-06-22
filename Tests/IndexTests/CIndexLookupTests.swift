import Testing
import Foundation
@testable import DeepFinderIndex

@Suite("CIndex id lookup")
struct CIndexLookupTests {

    @Test("id→meta lookup correct after swap-with-last removal")
    func lookupCorrectAfterSwapRemoval() async {
        let index = InMemoryIndex()
        // cindex_insert assigns auto-increment ids 1..4 in insertion order.
        for n in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            await index.insert(
                name: n,
                path: "/tmp/\(n)",
                parentPath: "/tmp",
                isDirectory: false,
                extension: "txt"
            )
        }

        // Remove id 2 (b.txt). cindex_remove swaps the last record (d.txt, id 4)
        // into the freed slot — the id_index must track that move.
        await index.remove(id: 2)

        // d.txt (id 4) relocated to a new array index; must still resolve.
        #expect(await index.record(for: 4)?.path == "/tmp/d.txt")
        #expect(await index.record(for: 1)?.path == "/tmp/a.txt")
        #expect(await index.record(for: 3)?.path == "/tmp/c.txt")
        // Removed id resolves to nil.
        #expect(await index.record(for: 2) == nil)
        // Non-existent id resolves to nil.
        #expect(await index.record(for: 999) == nil)
    }

    @Test("get-by-id is O(1) on a 50K index")
    func lookupIsO1() async {
        // buildIndex inserts 50K records; C assigns ids 1..50000 in order.
        let index = await PerformanceFixtures.buildIndex(count: 50_000)
        let ids: [UInt32] = stride(from: 1, to: 50_000, by: 5).map { UInt32($0) }

        // Warm up (first call may fault in pages).
        for id in ids.prefix(100) { _ = await index.record(for: id) }

        let start = ContinuousClock.now
        for id in ids { _ = await index.record(for: id) }
        let ms = (ContinuousClock.now - start) / .milliseconds(1)

        // O(1): ~tens of µs total. O(n) at 50K: 10K lookups × 50K iterations
        // each → many seconds. 50ms sits >1000× above O(1) and >50× below O(n),
        // so it cleanly separates the two regardless of machine speed.
        #expect(ms < 50, "id lookup must be O(1); got \(ms)ms for \(ids.count) lookups")
        print("[Benchmark] get-by-id \(ids.count)× on 50K index: \(String(format: "%.2f", ms))ms")
    }
}
