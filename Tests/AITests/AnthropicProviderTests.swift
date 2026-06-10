import Foundation
import Testing
@testable import DeepFinder

@Suite("AnthropicProvider")
struct AnthropicProviderTests {

    // MARK: - Conformance

    @Test("AnthropicProvider conforms to AIModelProvider")
    func conformsToAIModelProvider() {
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4-6-20251001",
            httpClient: MockHTTPClient(response: mockStopResponse())
        )
        func assertProvider<T: AIModelProvider>(_: T) {}
        assertProvider(provider)
    }

    // MARK: - name & displayName

    @Test("provider name and display name")
    func providerNameAndDisplayName() {
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            model: "claude-opus-4-5-20251101",
            httpClient: MockHTTPClient(response: mockStopResponse())
        )
        #expect(provider.name == "anthropic")
        #expect(provider.displayName == "Claude (Anthropic)")
        #expect(provider.supportsOnDevice == false)
        #expect(provider.hasEmbeddingAPI == false)
        #expect(provider.contextLimit == 200_000)
    }

    // MARK: - capabilities

    @Test("capabilities include text AI features, not local-only")
    func capabilities() {
        let provider = AnthropicProvider(
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4-6-20251001",
            httpClient: MockHTTPClient(response: mockStopResponse())
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

    @Test("complete streams content deltas from SSE")
    func completeStreamsContentDeltas() async throws {
        let response = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" world"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let http = MockHTTPClient(response: HTTPClientResponse(
            statusCode: 200, data: Data(response.utf8)
        ))
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-sonnet", httpClient: http)

        var chunks: [String] = []
        for try await chunk in provider.complete(prompt: "say hello", context: nil) {
            chunks.append(chunk)
        }
        #expect(chunks == ["hello", " world"])
    }

    @Test("complete skips non-content-delta events (message_start, ping)")
    func completeSkipsNonContentEvents() async throws {
        let response = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1"}}

        event: content_block_start
        data: {"type":"content_block_start","content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"result"}}

        event: content_block_stop
        data: {"type":"content_block_stop"}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let http = MockHTTPClient(response: HTTPClientResponse(statusCode: 200, data: Data(response.utf8)))
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-sonnet", httpClient: http)

        var chunks: [String] = []
        for try await chunk in provider.complete(prompt: "test", context: nil) {
            chunks.append(chunk)
        }
        #expect(chunks == ["result"])
    }

    // MARK: - translateToSearchSyntax()

    @Test("translateToSearchSyntax returns translated query")
    func translateToSearchSyntax() async throws {
        let response = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ext:mp4;mov size:>100mb"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let http = MockHTTPClient(response: HTTPClientResponse(statusCode: 200, data: Data(response.utf8)))
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-sonnet", httpClient: http)

        let result = try await provider.translateToSearchSyntax(naturalLanguage: "find big videos")
        #expect(result == "ext:mp4;mov size:>100mb")
    }

    // MARK: - Error handling

    @Test("complete maps HTTP 429 to rateLimited")
    func completeMaps429ToRateLimited() async {
        let http = MockHTTPClient(response: HTTPClientResponse(statusCode: 429, data: Data()))
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-sonnet", httpClient: http)

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
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-sonnet", httpClient: http)

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
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-sonnet", httpClient: http)

        let stream = provider.complete(prompt: "test", context: nil)
        do {
            for try await _ in stream {}
            Issue.record("Expected error, but stream completed normally")
        } catch {
            // Any error is acceptable since transport errors may propagate
            // as AIError.networkError or as the underlying URLError
        }
    }

    // MARK: - Retry behavior

    @Test("retry on 429 succeeds on second attempt")
    func retryOn429SucceedsOnSecondAttempt() async throws {
        let counter = SendableCounter()
        let response = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"retried"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let http = MockHTTPClient(handler: { _ in
            let call = counter.increment()
            if call == 1 {
                return HTTPClientResponse(statusCode: 429, data: Data())
            }
            return HTTPClientResponse(statusCode: 200, data: Data(response.utf8))
        })
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-sonnet", httpClient: http)
        var chunks: [String] = []
        for try await chunk in provider.complete(prompt: "test", context: nil) {
            chunks.append(chunk)
        }
        #expect(chunks == ["retried"])
        #expect(counter.value == 2)
    }

    @Test("retry max 3 attempts then fails with rateLimited")
    func retryMaxAttemptsThenRateLimited() async throws {
        let counter = SendableCounter()
        let http = MockHTTPClient(handler: { _ in
            counter.increment()
            return HTTPClientResponse(statusCode: 429, data: Data())
        })
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-sonnet", httpClient: http)
        do {
            for try await _ in provider.complete(prompt: "test", context: nil) {}
            Issue.record("Expected rateLimited error, but no error was thrown")
        } catch let error as AIError {
            #expect(error == .rateLimited)
        } catch {
            Issue.record("Expected AIError.rateLimited, got \(error)")
        }
        #expect(counter.value == 3)
    }

    @Test("retry on transport error succeeds on second attempt")
    func retryOnTransportErrorSucceedsOnSecondAttempt() async throws {
        let counter = SendableCounter()
        let response = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"recovered"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let http = MockHTTPClient(handler: { _ in
            let call = counter.increment()
            if call == 1 {
                throw URLError(.notConnectedToInternet)
            }
            return HTTPClientResponse(statusCode: 200, data: Data(response.utf8))
        })
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-sonnet", httpClient: http)
        var chunks: [String] = []
        for try await chunk in provider.complete(prompt: "test", context: nil) {
            chunks.append(chunk)
        }
        #expect(chunks == ["recovered"])
        #expect(counter.value == 2)
    }

    @Test("non-retryable HTTP errors throw immediately without retry")
    func nonRetryableHTTPErrorsThrowImmediately() async throws {
        let counter = SendableCounter()
        let http = MockHTTPClient(handler: { _ in
            counter.increment()
            return HTTPClientResponse(statusCode: 401, data: Data())
        })
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-sonnet", httpClient: http)
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
        #expect(counter.value == 1)
    }
}

// MARK: - Helpers

private func mockStopResponse() -> HTTPClientResponse {
    HTTPClientResponse(statusCode: 200, data: Data("""
    event: message_stop
    data: {"type":"message_stop"}

    """.utf8))
}
