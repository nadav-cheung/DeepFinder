import Testing
@testable import DeepFinder

@Suite("AutocompleteProvider")
struct AutocompleteTests {

    // MARK: - Helpers

    /// Build an InMemoryIndex with fixture data for autocomplete testing.
    private func makeIndex() async -> InMemoryIndex {
        let index = InMemoryIndex()
        // "report" appears in multiple names and paths
        await index.insert(name: "report.pdf", path: "/docs/report.pdf", parentPath: "/docs")
        await index.insert(name: "Report-2024.xlsx", path: "/docs/Report-2024.xlsx", parentPath: "/docs")
        await index.insert(name: "report", path: "/tmp/report", parentPath: "/tmp")
        await index.insert(name: "repository.swift", path: "/src/repository.swift", parentPath: "/src")
        await index.insert(name: "photo.jpg", path: "/pics/photo.jpg", parentPath: "/pics")
        await index.insert(name: "photo.png", path: "/pics/photo.png", parentPath: "/pics")
        await index.insert(name: "notes.md", path: "/notes.md", parentPath: "/")
        await index.insert(name: "notes.txt", path: "/archive/notes.txt", parentPath: "/archive")
        await index.insert(name: "notes", path: "/workspace/notes", parentPath: "/workspace")
        return index
    }

    // MARK: - Filename prefix suggestions

    @Test("Prefix 'rep' suggests 'report', 'repository', etc.")
    func testPrefixSuggestsMatchingNames() async {
        let provider = AutocompleteProvider(index: await makeIndex())
        let suggestions = await provider.suggest(prefix: "rep")

        // All suggestions must start with "rep" (case-insensitive)
        for suggestion in suggestions {
            let lowered = suggestion.lowercased()
            #expect(lowered.hasPrefix("rep"))
        }

        // Should include at least "report" and "repository"
        let lowered = suggestions.map { $0.lowercased() }
        #expect(lowered.contains("report.pdf"))
        #expect(lowered.contains("report"))
        #expect(lowered.contains("repository.swift"))
    }

    @Test("Empty prefix returns top N most common prefixes")
    func testEmptyPrefixReturnsTopNames() async {
        let index = await makeIndex()
        let provider = AutocompleteProvider(index: index)

        // Empty prefix should return some results (top N by frequency)
        let suggestions = await provider.suggest(prefix: "")
        #expect(!suggestions.isEmpty)

        // "notes" appears as 3 distinct paths (notes.md, notes.txt, notes)
        // so "notes" or a variant should rank high
        let lowered = suggestions.map { $0.lowercased() }
        #expect(lowered.contains(where: { $0.hasPrefix("notes") }))
    }

    @Test("Limit is respected")
    func testLimitRespected() async {
        let provider = AutocompleteProvider(index: await makeIndex())
        let suggestions = await provider.suggest(prefix: "", limit: 3)
        #expect(suggestions.count <= 3)
    }

    @Test("No matches returns empty array")
    func testNoMatchesReturnsEmpty() async {
        let provider = AutocompleteProvider(index: await makeIndex())
        let suggestions = await provider.suggest(prefix: "zzzzzzz")
        #expect(suggestions.isEmpty)
    }

    @Test("Search is case insensitive")
    func testCaseInsensitive() async {
        let provider = AutocompleteProvider(index: await makeIndex())
        let lower = await provider.suggest(prefix: "rep")
        let upper = await provider.suggest(prefix: "REP")
        let mixed = await provider.suggest(prefix: "Rep")

        // All should return the same results (case-insensitive matching)
        #expect(lower == upper)
        #expect(lower == mixed)
        #expect(!lower.isEmpty)
    }

    @Test("Deduplication: same filename in multiple paths counted once")
    func testDeduplication() async {
        let index = InMemoryIndex()
        // Insert the same filename "readme.md" in 3 different paths
        await index.insert(name: "readme.md", path: "/a/readme.md", parentPath: "/a")
        await index.insert(name: "readme.md", path: "/b/readme.md", parentPath: "/b")
        await index.insert(name: "readme.md", path: "/c/readme.md", parentPath: "/c")
        // Insert another file starting with "read"
        await index.insert(name: "readme.txt", path: "/d/readme.txt", parentPath: "/d")

        let provider = AutocompleteProvider(index: index)
        let suggestions = await provider.suggest(prefix: "readme")

        // "readme.md" should appear exactly once despite 3 paths
        let readmeMdCount = suggestions.filter { $0 == "readme.md" }.count
        #expect(readmeMdCount <= 1)

        // Both unique names should be present
        #expect(suggestions.contains("readme.md"))
        #expect(suggestions.contains("readme.txt"))
    }

    @Test("Single character prefix returns results")
    func testSingleCharacterPrefix() async {
        let provider = AutocompleteProvider(index: await makeIndex())
        let suggestions = await provider.suggest(prefix: "p")
        #expect(!suggestions.isEmpty)

        // Should find photo.jpg, photo.png
        let lowered = suggestions.map { $0.lowercased() }
        #expect(lowered.contains(where: { $0.hasPrefix("p") }))
    }

    // MARK: - Command suggestions

    @Test("Command suggestions for ':st' returns matching commands")
    func testCommandSuggestions() async {
        let provider = AutocompleteProvider(index: await makeIndex())
        let suggestions = provider.suggestCommands(prefix: ":st")

        // Should include :stats
        #expect(suggestions.contains(":stats"))

        // Should NOT include unrelated commands
        #expect(!suggestions.contains(":help"))
        #expect(!suggestions.contains(":quit"))
    }
}
