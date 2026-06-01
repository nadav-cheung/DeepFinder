import Foundation
@testable import DeepFinder

// MARK: - Mock HTTPClient shared by AI provider tests

/// A mock HTTPClient that returns a canned response or throws an error.
///
/// For multi-call scenarios (e.g., retry tests), use ``init(handler:timeout:)``
/// with a closure that tracks call count and returns different responses per call.
struct MockHTTPClient: HTTPClient {
    let requestTimeout: TimeInterval
    private let _perform: @Sendable (URLRequest) async throws -> HTTPClientResponse

    /// Returns a successful 200 response with empty body.
    init(timeout: TimeInterval = 30) {
        self.requestTimeout = timeout
        self._perform = { _ in HTTPClientResponse(statusCode: 200, data: Data()) }
    }

    init(response: HTTPClientResponse, timeout: TimeInterval = 30) {
        self.requestTimeout = timeout
        self._perform = { _ in response }
    }

    init(error: any Error, timeout: TimeInterval = 30) {
        self.requestTimeout = timeout
        self._perform = { _ in throw error }
    }

    /// Closure-based variant for multi-call scenarios (e.g., retry tests).
    /// The closure is invoked on every `perform(_:)` call, enabling different
    /// responses per attempt.
    init(handler: @escaping @Sendable (URLRequest) async throws -> HTTPClientResponse, timeout: TimeInterval = 30) {
        self.requestTimeout = timeout
        self._perform = handler
    }

    func perform(_ request: URLRequest) async throws -> HTTPClientResponse {
        try await _perform(request)
    }
}

// MARK: - SendableCounter

/// Thread-safe counter for use in `@Sendable` closures within tests.
/// Wraps an `Int` in a reference type, safe for concurrent access in test scenarios.
final class SendableCounter: @unchecked Sendable {
    var value: Int = 0
    private let lock = NSLock()

    @discardableResult
    func increment() -> Int {
        lock.lock()
        value += 1
        let result = value
        lock.unlock()
        return result
    }
}
