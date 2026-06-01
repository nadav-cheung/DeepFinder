import Foundation
import Testing
@testable import DeepFinder

@Suite("QwenProvider")
struct QwenProviderTests {

    // MARK: - Conformance

    @Test("QwenProvider conforms to AIModelProvider")
    func conformsToAIModelProvider() {
        let provider = QwenProvider.qwen(apiKey: "test-key", httpClient: MockHTTPClient())
        func assertProvider<T: AIModelProvider>(_: T) {}
        assertProvider(provider)
    }

    // MARK: - name

    @Test("name returns 'qwen'")
    func nameReturnsQwen() {
        let provider = QwenProvider.qwen(apiKey: "test-key", httpClient: MockHTTPClient())
        #expect(provider.name == "qwen")
    }

    // MARK: - capabilities

    @Test("capabilities includes textToSearch, resultSummary, querySuggestion, intentAnalysis")
    func capabilitiesCorrect() {
        let provider = QwenProvider.qwen(apiKey: "test-key", httpClient: MockHTTPClient())
        #expect(provider.capabilities.contains(.textToSearch))
        #expect(provider.capabilities.contains(.resultSummary))
        #expect(provider.capabilities.contains(.querySuggestion))
        #expect(provider.capabilities.contains(.intentAnalysis))
        #expect(!provider.capabilities.contains(.localVision))
        #expect(!provider.capabilities.contains(.localSpeech))
    }

    // MARK: - complete() streaming

    @Test("complete() returns stream of content chunks from SSE")
    func completeReturnsStream() async throws {
        let sseResponse = """
            data: {"choices":[{"delta":{"content":"你好"}}]}

            data: {"choices":[{"delta":{"content":"，"}}]}

            data: {"choices":[{"delta":{"content":"世界"}}]}

            data: [DONE]

            """
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 200,
                data: Data(sseResponse.utf8)
            )
        )
        let provider = QwenProvider.qwen(apiKey: "test-key", httpClient: mock)
        let stream = provider.complete(prompt: "hi", context: nil)
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        #expect(chunks == ["你好", "，", "世界"])
    }

    @Test("complete() handles empty delta content gracefully")
    func completeHandlesEmptyDelta() async throws {
        let sseResponse = """
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: {"choices":[{"delta":{"content":"result"}}]}

            data: [DONE]

            """
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 200,
                data: Data(sseResponse.utf8)
            )
        )
        let provider = QwenProvider.qwen(apiKey: "test-key", httpClient: mock)
        let stream = provider.complete(prompt: "hi", context: nil)
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        #expect(chunks == ["result"])
    }

    // MARK: - translateToSearchSyntax()

    @Test("translateToSearchSyntax() returns translated string")
    func translateToSearchSyntaxReturnsString() async throws {
        let sseResponse = """
            data: {"choices":[{"delta":{"content":"ext:mp4;mov size:>500mb dm:thisyear"}}]}

            data: [DONE]

            """
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 200,
                data: Data(sseResponse.utf8)
            )
        )
        let provider = QwenProvider.qwen(apiKey: "test-key", httpClient: mock)
        let result = try await provider.translateToSearchSyntax(naturalLanguage: "今年大于500MB的视频文件")
        #expect(result == "ext:mp4;mov size:>500mb dm:thisyear")
    }

    @Test("translateToSearchSyntax() strips markdown formatting")
    func translateStripsMarkdown() async throws {
        let sseResponse = """
            data: {"choices":[{"delta":{"content":"```\\next:pdf\\n```"}}]}

            data: [DONE]

            """
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 200,
                data: Data(sseResponse.utf8)
            )
        )
        let provider = QwenProvider.qwen(apiKey: "test-key", httpClient: mock)
        let result = try await provider.translateToSearchSyntax(naturalLanguage: "PDF文件")
        #expect(result == "ext:pdf")
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
        let provider = QwenProvider.qwen(apiKey: "test-key", httpClient: mock)
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

    @Test("HTTP 500 throws AIError.networkError")
    func serverErrorThrows() async {
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 500,
                data: Data("{\"error\":\"internal\"}".utf8)
            )
        )
        let provider = QwenProvider.qwen(apiKey: "test-key", httpClient: mock)
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

    // MARK: - Chinese language support

    @Test("translateToSearchSyntax handles Chinese input")
    func chineseInput() async throws {
        let sseResponse = """
            data: {"choices":[{"delta":{"content":"ext:xlsx;xls dm:thismonth"}}]}

            data: [DONE]

            """
        let mock = MockHTTPClient(
            response: HTTPClientResponse(
                statusCode: 200,
                data: Data(sseResponse.utf8)
            )
        )
        let provider = QwenProvider.qwen(apiKey: "test-key", httpClient: mock)
        let result = try await provider.translateToSearchSyntax(
            naturalLanguage: "这个月的Excel表格"
        )
        #expect(result.contains("ext:"))
        #expect(result.contains("dm:"))
    }
}
