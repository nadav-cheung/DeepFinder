import Foundation
import Testing
@testable import DeepFinder

@Suite("AIModelProvider")
struct AIModelProviderTests {

    // MARK: - AICapability

    @Test("AICapability has all required cases")
    func aiCapabilityAllCases() {
        let expected: Set<String> = [
            "textToSearch", "resultSummary", "querySuggestion",
            "intentAnalysis", "localVision", "localSpeech",
        ]
        let actual = Set(AICapability.allCases.map(\.rawValue))
        #expect(actual == expected)
    }

    @Test("AICapability is CaseIterable")
    func aiCapabilityCaseIterable() {
        #expect(AICapability.allCases.count == 6)
    }

    // MARK: - AIError

    @Test("AIError cases exist")
    func aiErrorCases() {
        let _: AIError = .notAvailable
        let _: AIError = .rateLimited
        let _: AIError = .invalidResponse
        let _: AIError = .timeout
        let _: AIError = .networkError("connection refused")
    }

    // MARK: - MockProvider conformance

    @Test("MockProvider name returns correct string")
    func mockProviderName() async {
        let provider = MockAIProvider()
        #expect(provider.name == "mock")
    }

    @Test("MockProvider capabilities returns correct set")
    func mockProviderCapabilities() async {
        let provider = MockAIProvider()
        #expect(provider.capabilities == Set(AICapability.allCases))
    }

    @Test("complete() returns AsyncThrowingStream of strings")
    func completeReturnsStream() async throws {
        let provider = MockAIProvider()
        let stream = provider.complete(prompt: "hello", context: nil)
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        #expect(chunks == ["mock", " ", "response"])
    }

    @Test("translateToSearchSyntax() returns a string")
    func translateToSearchSyntax() async throws {
        let provider = MockAIProvider()
        let result = try await provider.translateToSearchSyntax(naturalLanguage: "find big videos")
        #expect(result == "ext:mp4;mov;mkv size:>100mb")
    }

    @Test("MockProvider is Sendable")
    func mockProviderIsSendable() {
        let provider = MockAIProvider()
        // Compile-time check: passing to a Sendable-constrained function
        func assertSendable<T: Sendable>(_: T) {}
        assertSendable(provider)
    }
}

// MARK: - Mock Implementation

/// A mock AIModelProvider for testing.
final class MockAIProvider: AIModelProvider, @unchecked Sendable {
    let name: String = "mock"
    let capabilities: Set<AICapability> = Set(AICapability.allCases)

    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("mock")
            continuation.yield(" ")
            continuation.yield("response")
            continuation.finish()
        }
    }

    func translateToSearchSyntax(naturalLanguage: String) async throws -> String {
        "ext:mp4;mov;mkv size:>100mb"
    }
}
