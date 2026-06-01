import Foundation
@testable import DeepFinder

// MARK: - Mock HTTPClient shared by AI provider tests

/// A mock HTTPClient that returns a canned response or throws an error.
struct MockHTTPClient: HTTPClient {
    let requestTimeout: TimeInterval
    private let response: HTTPClientResponse?
    private let error: (any Error)?

    /// Returns a successful 200 response with empty body.
    init(timeout: TimeInterval = 30) {
        self.requestTimeout = timeout
        self.response = HTTPClientResponse(statusCode: 200, data: Data())
        self.error = nil
    }

    init(response: HTTPClientResponse, timeout: TimeInterval = 30) {
        self.requestTimeout = timeout
        self.response = response
        self.error = nil
    }

    init(error: any Error, timeout: TimeInterval = 30) {
        self.requestTimeout = timeout
        self.response = nil
        self.error = error
    }

    func perform(_ request: URLRequest) async throws -> HTTPClientResponse {
        if let error { throw error }
        return response!
    }
}
