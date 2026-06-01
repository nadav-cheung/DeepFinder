import Foundation
import Testing
@testable import DeepFinder

@Suite("GeminiProvider")
struct GeminiProviderTests {

    // MARK: - Conformance

    @Test("GeminiProvider conforms to AIModelProvider")
    func conformsToAIModelProvider() {
        let provider = GeminiProvider(
            apiKey: "test-key",
            model: "gemini-2.5-pro",
            httpClient: MockHTTPClient(response: mockGeminiResponse())
        )
        func assertProvider<T: AIModelProvider>(_: T) {}
        assertProvider(provider)
    }

    // MARK: - name & displayName

    @Test("provider name and display name")
    func providerNameAndDisplayName() async throws {
        let provider = GeminiProvider(
            apiKey: "test-key",
            model: "gemini-2.5-pro",
            httpClient: MockHTTPClient(response: mockGeminiResponse())
        )
        #expect(provider.name == "gemini")
        #expect(provider.displayName == "Google Gemini")
        #expect(provider.supportsOnDevice == false)
        #expect(provider.hasEmbeddingAPI == true)
        #expect(provider.contextLimit == 1_000_000)
    }

    // MARK: - capabilities

    @Test("capabilities include text AI features, not local-only")
    func capabilities() {
        let provider = GeminiProvider(
            apiKey: "test-key",
            model: "gemini-2.5-pro",
            httpClient: MockHTTPClient(response: mockGeminiResponse())
        )
        #expect(provider.capabilities.contains(.textToSearch))
        #expect(provider.capabilities.contains(.resultSummary))
        #expect(provider.capabilities.contains(.querySuggestion))
        #expect(provider.capabilities.contains(.intentAnalysis))
        // Does NOT include local-only capabilities
        #expect(!provider.capabilities.contains(.localVision))
        #expect(!provider.capabilities.contains(.localSpeech))
        #expect(!provider.capabilities.contains(.onDeviceTextAI))
    }

    // MARK: - complete() streaming

    @Test("complete streams content from candidates")
    func completeStreamsContent() async throws {
        let response = """
        data: {"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}

        data: {"candidates":[{"content":{"parts":[{"text":" world"}]}}]}

        """
        let http = MockHTTPClient(response: HTTPClientResponse(statusCode: 200, data: Data(response.utf8)))
        let provider = GeminiProvider(apiKey: "test-key", model: "gemini-2.5-flash", httpClient: http)

        var chunks: [String] = []
        for try await chunk in provider.complete(prompt: "say hello", context: nil) {
            chunks.append(chunk)
        }
        #expect(chunks == ["hello", " world"])
    }

    // MARK: - translateToSearchSyntax()

    @Test("translateToSearchSyntax returns translated query")
    func translateToSearchSyntax() async throws {
        let response = """
        data: {"candidates":[{"content":{"parts":[{"text":"ext:mp4;mov size:>100mb"}]}}]}

        """
        let http = MockHTTPClient(response: HTTPClientResponse(statusCode: 200, data: Data(response.utf8)))
        let provider = GeminiProvider(apiKey: "test-key", model: "gemini-2.5-pro", httpClient: http)
        let result = try await provider.translateToSearchSyntax(naturalLanguage: "find big videos")
        #expect(result == "ext:mp4;mov size:>100mb")
    }

    // MARK: - Error handling

    @Test("complete maps HTTP 429 to rateLimited")
    func completeMaps429ToRateLimited() async {
        let http = MockHTTPClient(response: HTTPClientResponse(statusCode: 429, data: Data()))
        let provider = GeminiProvider(apiKey: "test-key", model: "gemini-flash", httpClient: http)

        do {
            for try await _ in provider.complete(prompt: "test", context: nil) {}
            Issue.record("Expected rateLimited error, but no error was thrown")
        } catch let error as AIError {
            #expect(error == .rateLimited)
        } catch {
            Issue.record("Expected AIError.rateLimited, got \(error)")
        }
    }

    @Test("complete maps HTTP 401 to networkError")
    func completeMaps401ToNetworkError() async {
        let http = MockHTTPClient(response: HTTPClientResponse(statusCode: 401, data: Data()))
        let provider = GeminiProvider(apiKey: "test-key", model: "gemini-flash", httpClient: http)

        do {
            for try await _ in provider.complete(prompt: "test", context: nil) {}
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

    @Test("complete propagates transport errors")
    func completePropagatesTransportErrors() async {
        let http = MockHTTPClient(error: URLError(.notConnectedToInternet))
        let provider = GeminiProvider(apiKey: "test-key", model: "gemini-flash", httpClient: http)

        let stream = provider.complete(prompt: "test", context: nil)
        do {
            for try await _ in stream {}
            Issue.record("Expected error, but stream completed normally")
        } catch {
            // Any error is acceptable since transport errors may propagate
            // as AIError.networkError or as the underlying URLError
        }
    }

    // MARK: - endpoint URL

    @Test("endpoint URL includes model name")
    func endpointURLIncludesModelName() async throws {
        let provider = GeminiProvider(apiKey: "test-key", model: "gemini-2.5-pro",
                                       httpClient: MockHTTPClient(response: mockGeminiResponse()))
        #expect(provider.endpointURL?.absoluteString.contains("gemini-2.5-pro") ?? false)
    }
}

// MARK: - Helpers

private func mockGeminiResponse() -> HTTPClientResponse {
    HTTPClientResponse(statusCode: 200, data: Data("""
    data: {"candidates":[{"content":{"parts":[{"text":"test"}]}}]}

    """.utf8))
}

// Expose endpoint for testing
extension GeminiProvider {
    var endpointURL: URL? { endpoint }
}
