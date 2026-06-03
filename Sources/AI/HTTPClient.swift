/// HTTP transport abstraction for cloud AI providers, plus SSE line stream parser.
///
/// Protocol-based for testability (production uses URLSession, tests inject mocks).
/// SSELineSequence parses Server-Sent Events response bodies into individual lines
/// consumed by OpenAI-compatible providers.
import Foundation

// MARK: - HTTPClient

/// Protocol abstracting HTTP requests for testability.
///
/// Production uses `URLSessionHTTPClient` wrapping `URLSession`.
/// Tests inject `MockHTTPClient` returning canned responses.
///
/// **Privacy note**: This is the transport layer for cloud AI providers. The request
/// body is constructed by `OpenAICompatibleProvider` and contains only metadata from
/// ``AIContext``/``FileMetadataSummary`` -- never file contents. See the module-level
/// documentation in `AIModelProvider.swift` for the full privacy model.
protocol HTTPClient: Sendable {
    /// Perform an HTTP request and return the raw response.
    func perform(_ request: URLRequest) async throws -> HTTPClientResponse
    /// Timeout interval for each request, in seconds.
    var requestTimeout: TimeInterval { get }
}

// MARK: - HTTPClientResponse

/// The response from an HTTP request, abstracting `URLResponse` for testability.
struct HTTPClientResponse: Sendable {
    /// HTTP status code (e.g. 200, 429).
    let statusCode: Int
    /// Raw body data.
    let data: Data
    /// Response headers.
    let headers: [String: String]

    init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }
}

// MARK: - URLSessionHTTPClient

/// Production HTTP client backed by `URLSession`.
struct URLSessionHTTPClient: HTTPClient {
    let requestTimeout: TimeInterval
    private let session: URLSession

    init(timeout: TimeInterval = Constants.AI.requestTimeout, session: URLSession = .shared) {
        self.requestTimeout = timeout
        self.session = session
    }

    func perform(_ request: URLRequest) async throws -> HTTPClientResponse {
        var req = request
        req.timeoutInterval = requestTimeout
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.networkError("Non-HTTP response")
        }
        let headers = (http.allHeaderFields as? [String: String]) ?? [:]
        return HTTPClientResponse(statusCode: http.statusCode, data: data, headers: headers)
    }
}

// MARK: - SSE Line Stream

/// Reads an HTTP response body as a sequence of SSE lines.
///
/// DeepSeek and Qwen both return streaming responses as Server-Sent Events:
/// ```
/// data: {"choices":[{"delta":{"content":"hello"}}]}
/// data: {"choices":[{"delta":{"content":" world"}}]}
/// data: [DONE]
/// ```
///
/// Malformed lines (no "data: " prefix) are silently skipped by the caller
/// (`OpenAICompatibleProvider.complete()`). Lines that fail JSON parsing in
/// `parseContentDelta` are also silently skipped, so transient API glitches
/// (e.g., incomplete JSON due to network buffering) don't crash the stream.
struct SSELineSequence: AsyncSequence, Sendable {
    typealias Element = String
    let data: Data

    struct AsyncIterator: AsyncIteratorProtocol {
        let data: Data
        var offset: Data.Index = 0

        mutating func next() async -> String? {
            // Scan for "data: " prefix lines
            while offset < data.endIndex {
                // Find next newline
                guard let newline = data[offset...].firstIndex(of: UInt8(ascii: "\n")) else {
                    // Remaining data is the last line
                    if offset < data.endIndex {
                        let line = String(data: data[offset...], encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        offset = data.endIndex
                        return line.isEmpty ? nil : line
                    }
                    return nil
                }

                let line = String(data: data[offset..<newline], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                offset = data.index(after: newline)

                if line.isEmpty { continue }
                return line
            }
            return nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(data: data)
    }
}
