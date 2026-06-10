import Foundation
import Testing
@testable import DeepFinderAI

@Suite("SemanticGrouper")
struct SemanticGrouperTests {

    // MARK: - Returns nil for fewer than 20 results

    @Test("Returns nil for 0 results")
    func returnsNilForZeroResults() async {
        let provider = MockGrouperProvider(response: "Design|code|other")
        let grouper = SemanticGrouper(provider: provider)
        let result = await grouper.group(query: "test", results: [], ids: [])
        #expect(result == nil)
    }

    @Test("Returns nil for 19 results")
    func returnsNilFor19Results() async {
        let provider = MockGrouperProvider(response: "Design|code|other")
        let grouper = SemanticGrouper(provider: provider)
        let results = (0..<19).map { makeGrouperSummary(name: "file_\($0).txt") }
        let ids = Array(0..<19) as [UInt32]
        let result = await grouper.group(query: "test", results: results, ids: ids)
        #expect(result == nil)
    }

    // MARK: - Returns groups for 20+ results

    @Test("Returns groups for exactly 20 results")
    func returnsGroupsFor20Results() async {
        let provider = MockGrouperProvider(response: "Reports|Code|Other")
        let grouper = SemanticGrouper(provider: provider)
        let results = (0..<20).map { makeGrouperSummary(name: "file_\($0).txt") }
        let ids = Array(0..<20) as [UInt32]
        let result = await grouper.group(query: "test", results: results, ids: ids)
        #expect(result != nil)
        if let groups = result {
            #expect(!groups.isEmpty)
            // All file IDs must be covered
            let allGroupedIDs = groups.flatMap(\.fileIDs).sorted()
            #expect(allGroupedIDs == ids.sorted())
        }
    }

    @Test("Groups have non-empty names")
    func groupsHaveNames() async {
        let provider = MockGrouperProvider(response: "PDF Documents|Spreadsheets|Other")
        let grouper = SemanticGrouper(provider: provider)
        let results = (0..<25).map { makeGrouperSummary(name: "file_\($0).txt") }
        let ids = Array(0..<25) as [UInt32]
        let result = await grouper.group(query: "test", results: results, ids: ids)
        if let groups = result {
            for group in groups {
                #expect(!group.name.isEmpty)
            }
        }
    }

    // MARK: - Nil provider returns nil

    @Test("Nil provider returns nil")
    func nilProviderReturnsNil() async {
        let grouper = SemanticGrouper(provider: nil)
        let results = (0..<20).map { makeGrouperSummary(name: "file_\($0).txt") }
        let ids = Array(0..<20) as [UInt32]
        let result = await grouper.group(query: "test", results: results, ids: ids)
        #expect(result == nil)
    }

    // MARK: - Provider error returns nil

    @Test("Provider error returns nil")
    func providerErrorReturnsNil() async {
        let provider = MockGrouperProvider(response: nil)
        let grouper = SemanticGrouper(provider: provider)
        let results = (0..<20).map { makeGrouperSummary(name: "file_\($0).txt") }
        let ids = Array(0..<20) as [UInt32]
        let result = await grouper.group(query: "test", results: results, ids: ids)
        #expect(result == nil)
    }

    // MARK: - SemanticGroup Equatable

    @Test("SemanticGroup Equatable works")
    func semanticGroupEquatable() {
        let g1 = SemanticGroup(name: "Reports", fileIDs: [1, 2, 3])
        let g2 = SemanticGroup(name: "Reports", fileIDs: [1, 2, 3])
        let g3 = SemanticGroup(name: "Code", fileIDs: [1, 2, 3])
        #expect(g1 == g2)
        #expect(g1 != g3)
    }
}

// MARK: - Helpers

private func makeGrouperSummary(name: String) -> FileMetadataSummary {
    FileMetadataSummary(
        name: name,
        path: "~/Documents/\(name)",
        size: 1024,
        modifiedAt: Date(),
        extension: name.split(separator: ".").last.map(String.init),
        localTags: []
    )
}

// MARK: - Mock Provider for SemanticGrouper tests

final class MockGrouperProvider: AIModelProvider, @unchecked Sendable {
    let name: String = "mock-grouper"
    let capabilities: Set<AICapability> = [.resultSummary]

    private let response: String?

    init(response: String?) {
        self.response = response
    }

    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [self] continuation in
            Task { [self] in
                if let response {
                    continuation.yield(response)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: AIError.notAvailable)
                }
            }
        }
    }

    func translateToSearchSyntax(naturalLanguage: String) async throws -> String {
        return naturalLanguage
    }
}
