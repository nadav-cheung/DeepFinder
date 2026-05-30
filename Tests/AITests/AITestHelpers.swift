import Foundation
@testable import DeepFinder

// MARK: - Mock HTTPClient shared by AI provider tests

/// A mock HTTPClient that returns a canned response or throws an error.
struct MockHTTPClient: HTTPClient {
    private let response: HTTPClientResponse?
    private let error: (any Error)?

    /// Returns a successful 200 response with empty body.
    init() {
        self.response = HTTPClientResponse(statusCode: 200, data: Data())
        self.error = nil
    }

    init(response: HTTPClientResponse) {
        self.response = response
        self.error = nil
    }

    init(error: any Error) {
        self.response = nil
        self.error = error
    }

    func perform(_ request: URLRequest) async throws -> HTTPClientResponse {
        if let error { throw error }
        return response!
    }
}
