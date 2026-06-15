// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Testing
import Foundation
@testable import DeepFinderDaemon

@Suite("FilterStore")
struct FilterStoreTests {

    @Test("upsert adds and replaces by name")
    func upsertReplacesByName() async {
        let store = FilterStore()  // in-memory
        await store.upsert(name: "big", expression: "size:>10mb")
        #expect(await store.getAll().count == 1)

        // Same name replaces the expression, does not duplicate.
        await store.upsert(name: "big", expression: "size:>100mb")
        let all = await store.getAll()
        #expect(all.count == 1)
        #expect(all.first?.expression == "size:>100mb")
    }

    @Test("delete by name; missing name returns false")
    func deleteByName() async {
        let store = FilterStore()
        await store.upsert(name: "a", expression: "ext:pdf")
        #expect(await store.delete(name: "a") == true)
        #expect(await store.getAll().isEmpty)
        #expect(await store.delete(name: "missing") == false)
    }

    @Test("find by exact name")
    func findByName() async {
        let store = FilterStore()
        await store.upsert(name: "work", expression: "ext:pdf dm:today")
        #expect(await store.find(name: "work")?.expression == "ext:pdf dm:today")
        #expect(await store.find(name: "nope") == nil)
    }

    @Test("persistence round-trips across instances")
    func persistenceRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("filters.json").path

        let s1 = FilterStore(filePath: path)
        await s1.upsert(name: "work", expression: "ext:pdf dm:today")
        await s1.upsert(name: "code", expression: "ext:swift")

        let s2 = FilterStore(filePath: path)
        let all = await s2.getAll()
        #expect(all.count == 2)
        #expect(all.contains { $0.name == "work" && $0.expression == "ext:pdf dm:today" })
        #expect(all.contains { $0.name == "code" && $0.expression == "ext:swift" })
    }
}
