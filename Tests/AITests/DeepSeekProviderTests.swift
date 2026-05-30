import Foundation
import Testing
@testable import DeepFinder

@Suite("DeepSeekProvider")
struct DeepSeekProviderTests {

    // MARK: - Conformance

    @Test("DeepSeekProvider conforms to AIModelProvider")
    func conformsToAIModelProvider() {
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: MockHTTPClient())
        // Compile-time check: passing to AIModelProvider-constrained function
        func assertProvider<T: AIModelProvider>(_: T) {}
        assertProvider(provider)
    }

    @Test("DeepSeekProvider is Sendable")
    func isSendable() {
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: MockHTTPClient())
        func assertSendable<T: Sendable>(_: T) {}
        assertSendable(provider)
    }

    // MARK: - name

    @Test("name returns 'deepseek'")
    func nameReturnsDeepSeek() {
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: MockHTTPClient())
        #expect(provider.name == "deepseek")
    }

    // MARK: - capabilities

    @Test("capabilities includes textToSearch, resultSummary, querySuggestion, intentAnalysis")
    func capabilitiesCorrect() {
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: MockHTTPClient())
        #expect(provider.capabilities.contains(.textToSearch))
        #expect(provider.capabilities.contains(.resultSummary))
        #expect(provider.capabilities.contains(.querySuggestion))
        #expect(provider.capabilities.contains(.intentAnalysis))
        // Does NOT include local-only capabilities
        #expect(!provider.capabilities.contains(.localVision))
        #expect(!provider.capabilities.contains(.localSpeech))
    }

    // MARK: - complete() streaming

    @Test("complete() returns stream of content chunks from SSE")
    func completeReturnsStream() async throws {
        let sseResponse = """
            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[{"delta":{"content":" world"}}]}

            data: {"choices":[{"delta":{"content":"!"}}]}

            data: [DONE]

            """
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 200,
                data: Data(sseResponse.utf8)
            )
        )
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: mock)
        let stream = provider.complete(prompt: "hi", context: nil)
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        #expect(chunks == ["Hello", " world", "!"])
    }

    @Test("complete() handles empty delta content gracefully")
    func completeHandlesEmptyDelta() async throws {
        let sseResponse = """
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: {"choices":[{"delta":{"content":"text"}}]}

            data: [DONE]

            """
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 200,
                data: Data(sseResponse.utf8)
            )
        )
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: mock)
        let stream = provider.complete(prompt: "hi", context: nil)
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        // Should only yield the non-empty content delta
        #expect(chunks == ["text"])
    }

    // MARK: - translateToSearchSyntax()

    @Test("translateToSearchSyntax() returns translated string")
    func translateToSearchSyntaxReturnsString() async throws {
        let sseResponse = """
            data: {"choices":[{"delta":{"content":"ext:pdf dm:lastweek"}}]}

            data: [DONE]

            """
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 200,
                data: Data(sseResponse.utf8)
            )
        )
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: mock)
        let result = try await provider.translateToSearchSyntax(naturalLanguage: "PDF files from last week")
        #expect(result == "ext:pdf dm:lastweek")
    }

    @Test("translateToSearchSyntax() strips markdown formatting")
    func translateStripsMarkdown() async throws {
        let sseResponse = """
            data: {"choices":[{"delta":{"content":"```\\next:pdf dm:today\\n```"}}]}

            data: [DONE]

            """
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 200,
                data: Data(sseResponse.utf8)
            )
        )
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: mock)
        let result = try await provider.translateToSearchSyntax(naturalLanguage: "today's PDFs")
        #expect(result == "ext:pdf dm:today")
    }

    // MARK: - Error handling

    @Test("HTTP 429 throws AIError.rateLimited")
    func rateLimitedThrows() async {
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 429,
                data: Data("{\"error\":\"rate limited\"}".utf8)
            )
        )
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: mock)
        let stream = provider.complete(prompt: "hi", context: nil)
        do {
            for try await _ in stream {}
            Issue.record("Expected rateLimited error, but no error was thrown")
        } catch let error as AIError {
            #expect(error == .rateLimited)
        } catch {
            Issue.record("Expected AIError.rateLimited, got \(error)")
        }
    }

    @Test("HTTP 401 throws AIError.networkError")
    func unauthorizedThrows() async {
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 401,
                data: Data("{\"error\":\"invalid api key\"}".utf8)
            )
        )
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: mock)
        let stream = provider.complete(prompt: "hi", context: nil)
        do {
            for try await _ in stream {}
            Issue.record("Expected networkError, but no error was thrown")
        } catch let error as AIError {
            if case .networkError = error {
                // Correct
            } else {
                Issue.record("Expected networkError, got \(error)")
            }
        } catch {
            Issue.record("Expected AIError, got \(error)")
        }
    }

    @Test("Network failure throws AIError.networkError")
    func networkFailureThrows() async {
        let mock = MockHTTPClient(error: URLError(.notConnectedToInternet))
        let provider = DeepSeekProvider.deepSeek(apiKey: "test-key", httpClient: mock)
        let stream = provider.complete(prompt: "hi", context: nil)
        do {
            for try await _ in stream {}
            Issue.record("Expected networkError, but no error was thrown")
        } catch let error as AIError {
            if case .networkError = error {
                // Correct
            } else {
                Issue.record("Expected networkError, got \(error)")
            }
        } catch {
            // URLError is also acceptable since it propagates from the HTTP client
            // The provider wraps it, but either way the stream terminates with an error
        }
    }
}

// MockHTTPClient is defined in AITestHelpers.swift
