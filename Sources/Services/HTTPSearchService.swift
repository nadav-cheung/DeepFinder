import Foundation
import Network

// MARK: - HTTPSearchService

/// A lightweight HTTP server exposing DeepFinder search via localhost.
///
/// Uses Network.framework `NWListener` — zero external dependencies.
/// Listens on 127.0.0.1 only. Returns JSON with CORS headers.
///
/// Routes:
/// - `GET /health` -> `{"status":"ok"}`
/// - `GET /search?q=...&limit=N&offset=N` -> search results via `searchHandler`
/// - `GET /stats` -> index stats via `statsHandler`
/// - All other routes -> 404
actor HTTPSearchService {

    // MARK: - Types

    /// Handler invoked for `/search` requests. Returns an array of dictionaries
    /// (each representing one result) given query, limit, and offset.
    typealias SearchHandler = @Sendable (String, Int, Int) async -> [[String: String]]

    /// Handler invoked for `/stats` requests. Returns a stats dictionary.
    typealias StatsHandler = @Sendable () async -> [String: Any]

    // MARK: - Properties

    private let port: UInt16
    private let searchHandler: SearchHandler
    private let statsHandler: StatsHandler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "http-search-service", attributes: .concurrent)

    /// The actual port the server is listening on. Nil if not started.
    var listeningPort: UInt16? {
        listener?.port?.rawValue
    }

    /// Whether the server is currently running.
    var isRunning: Bool {
        listener != nil
    }

    // MARK: - Init

    init(
        port: UInt16 = 7654,
        searchHandler: @escaping SearchHandler,
        statsHandler: @escaping StatsHandler
    ) {
        self.port = port
        self.searchHandler = searchHandler
        self.statsHandler = statsHandler
    }

    // MARK: - Lifecycle

    /// Start the HTTP server and wait for it to become ready.
    func start() async throws {
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()

        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: parameters, on: nwPort)

        let readyContinuation = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readyContinuation.continuation.yield()
            case .failed(let error):
                print("[HTTPSearchService] Listener failed: \(error)")
                readyContinuation.continuation.yield()
            case .waiting(let error):
                print("[HTTPSearchService] Listener waiting: \(error)")
            default:
                break
            }
        }

        // Capture handlers by value before the closure — they are @Sendable,
        // so this is safe and avoids reading actor-isolated properties from
        // the NWListener dispatch queue.
        let handler = searchHandler
        let stats = statsHandler

        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "http-conn", attributes: .concurrent))
            // Buffer incoming data until we have the full HTTP header (\r\n\r\n).
            // A single receive() may only get a TCP fragment.
            var buffer = Data()
            func readNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    guard let data, error == nil else {
                        connection.cancel()
                        return
                    }
                    buffer.append(data)
                    let headerEnd = Data("\r\n\r\n".utf8)
                    if let range = buffer.range(of: headerEnd) {
                        // We have the full header — use everything up to and including \r\n\r\n
                        HTTPRouter.handleRequest(
                            data: buffer,
                            connection: connection,
                            searchHandler: handler,
                            statsHandler: stats
                        )
                    } else {
                        readNext()
                    }
                }
            }
            readNext()
        }

        listener.start(queue: queue)
        self.listener = listener

        // Wait for the listener to become ready (or fail)
        for await _ in readyContinuation.stream {
            break
        }
    }

    /// Stop the HTTP server.
    func stop() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - HTTPRouter

/// Stateless HTTP request parser and router.
/// Separated from the actor for testability — all routing logic can be tested
/// without starting a network server.
enum HTTPRouter {

    /// Represents a parsed HTTP request.
    struct HTTPRequest {
        let method: String
        let path: String
        let queryParams: [String: String]
    }

    /// Parse raw HTTP request data into an HTTPRequest.
    static func parseRequest(data: Data) -> HTTPRequest? {
        guard let requestString = String(data: data, encoding: .utf8) else { return nil }
        let requestLine = requestString.split(separator: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3 else { return nil }

        let method = String(parts[0])
        // Only accept standard HTTP methods
        guard ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"].contains(method) else { return nil }
        // Third part must be an HTTP version string
        guard parts[2].hasPrefix("HTTP/") else { return nil }

        let fullPath = String(parts[1])

        let urlComponents = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(urlComponents[0])
        let queryString = urlComponents.count > 1 ? String(urlComponents[1]) : ""
        let queryParams = parseQueryParams(queryString)

        return HTTPRequest(method: method, path: path, queryParams: queryParams)
    }

    /// Route a parsed request and produce a response body + status code.
    static func route(
        request: HTTPRequest,
        searchResults: [[String: String]] = [],
        stats: [String: Any] = [:]
    ) -> (statusCode: Int, body: String) {
        guard request.method == "GET" else {
            return (405, "{\"error\":\"Method not allowed\"}")
        }

        switch request.path {
        case "/health":
            return (200, "{\"status\":\"ok\"}")

        case "/search":
            let query = request.queryParams["q"] ?? ""
            let limit = Int(request.queryParams["limit"] ?? "100") ?? 100
            let offset = Int(request.queryParams["offset"] ?? "0") ?? 0
            let responseDict: [String: Any] = [
                "query": query,
                "results": searchResults,
                "total": searchResults.count,
                "offset": offset,
                "limit": limit,
            ]
            return (200, jsonString(from: responseDict))

        case "/stats":
            return (200, jsonString(from: stats))

        default:
            return (404, "{\"error\":\"Not found\"}")
        }
    }

    /// Handle a raw request: parse, route, and send response over the connection.
    static func handleRequest(
        data: Data,
        connection: NWConnection,
        searchHandler: @escaping HTTPSearchService.SearchHandler,
        statsHandler: @escaping HTTPSearchService.StatsHandler
    ) {
        guard let request = parseRequest(data: data) else {
            sendResponse(connection: connection, statusCode: 400, body: "{\"error\":\"Bad request\"}")
            return
        }

        switch request.path {
        case "/health":
            sendResponse(connection: connection, statusCode: 200, body: "{\"status\":\"ok\"}")

        case "/search":
            let query = request.queryParams["q"] ?? ""
            let limit = Int(request.queryParams["limit"] ?? "100") ?? 100
            let offset = Int(request.queryParams["offset"] ?? "0") ?? 0
            Task {
                let results = await searchHandler(query, limit, offset)
                let responseDict: [String: Any] = [
                    "query": query,
                    "results": results,
                    "total": results.count,
                    "offset": offset,
                    "limit": limit,
                ]
                sendResponse(connection: connection, statusCode: 200, body: jsonString(from: responseDict))
            }

        case "/stats":
            Task {
                let stats = await statsHandler()
                sendResponse(connection: connection, statusCode: 200, body: jsonString(from: stats))
            }

        default:
            sendResponse(connection: connection, statusCode: 404, body: "{\"error\":\"Not found\"}")
        }
    }

    // MARK: - Response

    /// Build and send an HTTP response.
    static func sendResponse(connection: NWConnection, statusCode: Int, body: String) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Unknown"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        let headerLines = [
            "HTTP/1.1 \(statusCode) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(bodyData.count)",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
        ]
        let headerString = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        let responseData = headerString.data(using: .utf8)! + bodyData

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Helpers

    static func parseQueryParams(_ queryString: String) -> [String: String] {
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            params[key] = value
        }
        return params
    }

    static func jsonString(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Build a full HTTP response string (for testing).
    static func buildResponse(statusCode: Int, body: String) -> String {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Unknown"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        let headerLines = [
            "HTTP/1.1 \(statusCode) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(bodyData.count)",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
        ]
        return headerLines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }
}
