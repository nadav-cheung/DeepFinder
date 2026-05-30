import Foundation

// MARK: - HTTPClient

/// Protocol abstracting HTTP requests for testability.
///
/// Production uses `URLSessionHTTPClient` wrapping `URLSession`.
/// Tests inject `MockHTTPClient` returning canned responses.
protocol HTTPClient: Sendable {
    /// Perform an HTTP request and return the raw response.
    func perform(_ request: URLRequest) async throws -> HTTPClientResponse
}

// MARK: - HTTPClientResponse

/// The response from an HTTP request, abstracting `URLResponse` for testability.
struct HTTPClientResponse: Sendable {
    /// HTTP status code (e.g. 200, 429).
    let statusCode: Int
    /// Raw body data.
    let data: Data
}

// MARK: - URLSessionHTTPClient

/// Production HTTP client backed by `URLSession`.
struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func perform(_ request: URLRequest) async throws -> HTTPClientResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.networkError("Non-HTTP response")
        }
        return HTTPClientResponse(statusCode: http.statusCode, data: data)
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
