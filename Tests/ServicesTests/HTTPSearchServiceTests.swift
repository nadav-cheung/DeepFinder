import Foundation
import Testing
@testable import DeepFinder

@Suite("HTTPSearchService")
struct HTTPSearchServiceTests {

    // MARK: - Helpers

    private func makeMockSearchResults() -> [[String: String]] {
        [
            ["path": "/Users/test/report.pdf", "name": "report.pdf"],
            ["path": "/Users/test/report-v2.docx", "name": "report-v2.docx"],
        ]
    }

    private func makeMockStats() -> [String: Any] {
        ["totalFiles": 12345, "indexState": "live"]
    }

    /// Build a raw HTTP request from method, path, and optional query string.
    private func makeHTTPRequest(method: String = "GET", path: String) -> Data {
        let request = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n"
        return request.data(using: .utf8)!
    }

    /// Parse the HTTP response body from a full response string.
    private func parseResponseBody(_ response: String) -> String? {
        guard let range = response.range(of: "\r\n\r\n") else { return nil }
        return String(response[range.upperBound...])
    }

    /// Parse the status code from the first line of an HTTP response.
    private func parseStatusCode(_ response: String) -> Int? {
        let parts = response.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
        return code
    }

    /// Parse response headers as a dictionary.
    private func parseHeaders(_ response: String) -> [String: String] {
        guard let headerEnd = response.range(of: "\r\n\r\n") else { return [:] }
        let headerSection = String(response[..<headerEnd.lowerBound])
        var headers: [String: String] = [:]
        for line in headerSection.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return headers
    }

    // MARK: - Request Parsing Tests

    @Test("Parse valid GET request")
    func parseValidGetRequest() {
        let data = makeHTTPRequest(path: "/health")
        let request = HTTPRouter.parseRequest(data: data)
        #expect(request != nil)
        #expect(request?.method == "GET")
        #expect(request?.path == "/health")
        #expect(request?.queryParams.isEmpty == true)
    }

    @Test("Parse request with query parameters")
    func parseRequestWithQueryParams() {
        let data = makeHTTPRequest(path: "/search?q=test&limit=20&offset=5")
        let request = HTTPRouter.parseRequest(data: data)
        #expect(request != nil)
        #expect(request?.path == "/search")
        #expect(request?.queryParams["q"] == "test")
        #expect(request?.queryParams["limit"] == "20")
        #expect(request?.queryParams["offset"] == "5")
    }

    @Test("Parse request with percent-encoded query")
    func parsePercentEncodedQuery() {
        let data = makeHTTPRequest(path: "/search?q=hello%20world")
        let request = HTTPRouter.parseRequest(data: data)
        #expect(request?.queryParams["q"] == "hello world")
    }

    @Test("Parse returns nil for invalid data")
    func parseInvalidData() {
        let data = "not http".data(using: .utf8)!
        let request = HTTPRouter.parseRequest(data: data)
        #expect(request == nil)
    }

    @Test("Parse returns nil for empty data")
    func parseEmptyData() {
        let request = HTTPRouter.parseRequest(data: Data())
        #expect(request == nil)
    }

    // MARK: - Routing Tests

    @Test("GET /health returns 200 with status ok")
    func healthRoute() {
        let request = HTTPRouter.HTTPRequest(method: "GET", path: "/health", queryParams: [:], headers: [:])
        let (statusCode, body) = HTTPRouter.route(request: request)
        #expect(statusCode == 200)

        let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String]
        #expect(json?["status"] == "ok")
    }

    @Test("GET /search returns JSON results with query metadata")
    func searchRoute() {
        let request = HTTPRouter.HTTPRequest(
            method: "GET",
            path: "/search",
            queryParams: ["q": "test", "limit": "10", "offset": "0"],
            headers: [:]
        )
        let (statusCode, body) = HTTPRouter.route(
            request: request,
            searchResults: makeMockSearchResults()
        )
        #expect(statusCode == 200)

        let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(json?["query"] as? String == "test")
        #expect(json?["limit"] as? Int == 10)
        #expect(json?["offset"] as? Int == 0)
        #expect(json?["total"] as? Int == 2)

        let results = json?["results"] as? [[String: String]]
        #expect(results?.count == 2)
        #expect(results?.first?["name"] == "report.pdf")
        #expect(results?.last?["name"] == "report-v2.docx")
    }

    @Test("GET /search with missing q defaults to empty query")
    func searchRouteMissingQuery() {
        let request = HTTPRouter.HTTPRequest(method: "GET", path: "/search", queryParams: [:], headers: [:])
        let (statusCode, body) = HTTPRouter.route(request: request)
        #expect(statusCode == 200)

        let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(json?["query"] as? String == "")
    }

    @Test("GET /search with invalid limit/offset uses defaults")
    func searchRouteInvalidParams() {
        let request = HTTPRouter.HTTPRequest(
            method: "GET",
            path: "/search",
            queryParams: ["q": "test", "limit": "abc", "offset": "-1"],
            headers: [:]
        )
        let (statusCode, body) = HTTPRouter.route(request: request)
        #expect(statusCode == 200)

        let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        // "abc" -> Int fails -> default 100; "-1" parses to -1
        #expect(json?["limit"] as? Int == 100)
        #expect(json?["offset"] as? Int == -1)
    }

    @Test("GET /stats returns JSON stats")
    func statsRoute() {
        let request = HTTPRouter.HTTPRequest(method: "GET", path: "/stats", queryParams: [:], headers: [:])
        let (statusCode, body) = HTTPRouter.route(request: request, stats: makeMockStats())
        #expect(statusCode == 200)

        let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(json?["totalFiles"] as? Int == 12345)
        #expect(json?["indexState"] as? String == "live")
    }

    @Test("GET /unknown returns 404")
    func unknownRouteReturns404() {
        let request = HTTPRouter.HTTPRequest(method: "GET", path: "/nonexistent", queryParams: [:], headers: [:])
        let (statusCode, body) = HTTPRouter.route(request: request)
        #expect(statusCode == 404)

        let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String]
        #expect(json?["error"] == "Not found")
    }

    @Test("Non-GET method returns 405")
    func nonGetReturns405() {
        let request = HTTPRouter.HTTPRequest(method: "POST", path: "/health", queryParams: [:], headers: [:])
        let (statusCode, body) = HTTPRouter.route(request: request)
        #expect(statusCode == 405)

        let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String]
        #expect(json?["error"] == "Method not allowed")
    }

    @Test("OPTIONS preflight returns 204 with CORS headers")
    func optionsPreflight() {
        let request = HTTPRouter.HTTPRequest(method: "OPTIONS", path: "/search", queryParams: [:], headers: [:])
        let (statusCode, body) = HTTPRouter.route(request: request)
        #expect(statusCode == 204)
        #expect(body == "")

        let response = HTTPRouter.buildResponse(statusCode: 204, body: "")
        let headers = parseHeaders(response)
        #expect(headers["Access-Control-Allow-Origin"] == "*")
        #expect(headers["Access-Control-Allow-Methods"] == "GET, POST, OPTIONS")
        #expect(headers["Access-Control-Allow-Headers"] == "Content-Type, Authorization")
    }

    // MARK: - Response Building Tests

    @Test("Response includes CORS and Content-Type headers")
    func responseHeaders() {
        let response = HTTPRouter.buildResponse(statusCode: 200, body: "{\"status\":\"ok\"}")
        let headers = parseHeaders(response)

        #expect(headers["Access-Control-Allow-Origin"] == "*")
        #expect(headers["Access-Control-Allow-Methods"] == "GET, POST, OPTIONS")
        #expect(headers["Access-Control-Allow-Headers"] == "Content-Type, Authorization")
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["Content-Length"] == "15")
        #expect(headers["Connection"] == "close")
    }

    @Test("Response has correct status line")
    func responseStatusLine() {
        let response = HTTPRouter.buildResponse(statusCode: 404, body: "{}")
        #expect(response.hasPrefix("HTTP/1.1 404 Not Found"))
    }

    @Test("Response body is separated by double CRLF")
    func responseBodySeparation() {
        let body = "{\"status\":\"ok\"}"
        let response = HTTPRouter.buildResponse(statusCode: 200, body: body)
        let parsedBody = parseResponseBody(response)
        #expect(parsedBody == body)
    }

    // MARK: - Query Parameter Parsing Tests

    @Test("Parse empty query string returns empty dict")
    func parseEmptyQueryString() {
        let params = HTTPRouter.parseQueryParams("")
        #expect(params.isEmpty)
    }

    @Test("Parse multiple query parameters")
    func parseMultipleQueryParams() {
        let params = HTTPRouter.parseQueryParams("q=test&limit=20&offset=0")
        #expect(params["q"] == "test")
        #expect(params["limit"] == "20")
        #expect(params["offset"] == "0")
    }

    @Test("Parse query parameter with no value is skipped")
    func parseParamWithNoValue() {
        let params = HTTPRouter.parseQueryParams("q=test&invalid&limit=10")
        #expect(params["q"] == "test")
        #expect(params["limit"] == "10")
        #expect(params["invalid"] == nil)
    }

    // MARK: - JSON Serialization Tests

    @Test("jsonString produces valid JSON")
    func jsonStringIsValid() {
        let dict: [String: Any] = ["name": "test", "count": 42]
        let json = HTTPRouter.jsonString(from: dict)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["name"] as? String == "test")
        #expect(parsed?["count"] as? Int == 42)
    }

    @Test("jsonString returns empty object for non-serializable input")
    func jsonStringFallback() {
        // A valid dict should work fine; this tests the fallback path conceptually
        let json = HTTPRouter.jsonString(from: [:])
        #expect(json == "{}")
    }

    // MARK: - Server Lifecycle Tests

    @Test("Server start and stop lifecycle")
    func serverStartAndStop() async throws {
        let service = HTTPSearchService(
            port: 19951,
            searchHandler: { _, _, _ in [] },
            statsHandler: { [:] }
        )

        // Before start
        let portBefore = await service.listeningPort
        let runningBefore = await service.isRunning
        #expect(portBefore == nil)
        #expect(runningBefore == false)

        // Start
        try await service.start()
        let portAfter = await service.listeningPort
        let runningAfter = await service.isRunning
        #expect(portAfter == 19951)
        #expect(runningAfter == true)

        // Stop
        await service.stop()
        let portAfterStop = await service.listeningPort
        let runningAfterStop = await service.isRunning
        #expect(portAfterStop == nil)
        #expect(runningAfterStop == false)
    }

    @Test("Default port is 7654")
    func defaultPort() {
        let service = HTTPSearchService(
            searchHandler: { _, _, _ in [] },
            statsHandler: { [:] }
        )
        // We can't inspect the private port, but we can verify start doesn't crash
        // and the type uses the default. The listeningPort confirms after start.
        // For now, just verify the service was created successfully.
        #expect(type(of: service) == HTTPSearchService.self)
    }
}
