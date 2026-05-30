import Foundation

/// Protocol version for forward compatibility.
///
/// Incremented when the wire format changes in a non-backward-compatible way.
/// Old CLI versions can detect incompatibility and prompt the user to upgrade.
/// This value is embedded in every ``IPCRequest`` encoding.
let ipcProtocolVersion = 1

// MARK: - IPCError

/// Fine-grained error types returned in IPC error responses.
enum IPCError: Codable, Sendable, Equatable {
    /// The daemon is still starting up and not ready to serve queries.
    case daemonNotReady
    /// The query could not be processed (syntax error, too long, etc.).
    case queryError(String)
    /// The request was malformed or missing required fields.
    case invalidRequest(String)
    /// The operation requires Full Disk Access or another permission.
    case permissionDenied(String)
}

// MARK: - IPCRequest

/// All message types a client can send to the daemon.
enum IPCRequest: Codable, Sendable, Equatable {
    /// Protocol version — included in every encoded message for forward compat.
    private enum CodingKeys: String, CodingKey {
        case ipcProtocolVersion
        case kind
        case query
        case limit
        case queryID
        case key
        case value
    }

    private enum Kind: String, Codable {
        case query, cancel, stats, configGet, configSet, indexStatus
    }

    /// Execute a search query with an optional result limit.
    case query(_ query: String, limit: Int?)
    /// Cancel an in-flight query by its identifier.
    case cancel(queryID: String)
    /// Request daemon statistics (file count, uptime, memory usage).
    case stats
    /// Read one or all configuration values. Pass `nil` for all keys.
    case configGet(key: String?)
    /// Update a single configuration key-value pair.
    case configSet(key: String, value: String)
    /// Request current index state and file count.
    case indexStatus

    // Custom Codable: encodes a `kind` discriminator + `ipcProtocolVersion` field.

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ipcProtocolVersion, forKey: .ipcProtocolVersion)
        switch self {
        case .query(let q, let lim):
            try c.encode(Kind.query, forKey: .kind)
            try c.encode(q, forKey: .query)
            try c.encodeIfPresent(lim, forKey: .limit)
        case .cancel(let qid):
            try c.encode(Kind.cancel, forKey: .kind)
            try c.encode(qid, forKey: .queryID)
        case .stats:
            try c.encode(Kind.stats, forKey: .kind)
        case .configGet(let k):
            try c.encode(Kind.configGet, forKey: .kind)
            try c.encodeIfPresent(k, forKey: .key)
        case .configSet(let k, let v):
            try c.encode(Kind.configSet, forKey: .kind)
            try c.encode(k, forKey: .key)
            try c.encode(v, forKey: .value)
        case .indexStatus:
            try c.encode(Kind.indexStatus, forKey: .kind)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .query:
            let q = try c.decode(String.self, forKey: .query)
            let lim = try c.decodeIfPresent(Int.self, forKey: .limit)
            self = .query(q, limit: lim)
        case .cancel:
            let qid = try c.decode(String.self, forKey: .queryID)
            self = .cancel(queryID: qid)
        case .stats:
            self = .stats
        case .configGet:
            let k = try c.decodeIfPresent(String.self, forKey: .key)
            self = .configGet(key: k)
        case .configSet:
            let k = try c.decode(String.self, forKey: .key)
            let v = try c.decode(String.self, forKey: .value)
            self = .configSet(key: k, value: v)
        case .indexStatus:
            self = .indexStatus
        }
    }
}

// MARK: - DaemonStats

/// Runtime statistics reported by the daemon.
struct DaemonStats: Codable, Sendable, Equatable {
    /// Total number of files currently in the index.
    let totalFiles: Int
    /// Current index state as a string (e.g. "live", "verifying", "polling").
    let indexState: String
    /// Seconds since the daemon process started.
    let uptimeSeconds: Double
    /// Approximate memory usage of the daemon process in megabytes.
    let memoryUsageMB: Double
}

// MARK: - DaemonIndexStatus

/// Current state of the file index as reported by the daemon.
struct DaemonIndexStatus: Codable, Sendable, Equatable {
    /// Index state as a string (e.g. "stale", "verifying", "live", "polling").
    let state: String
    /// Number of files currently indexed.
    let filesIndexed: Int
    /// Timestamp of the last full scan, if available.
    let lastScanDate: Date?
}

// MARK: - IPCResponse

/// All message types the daemon can send back to a client.
enum IPCResponse: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case kind, results, queryID, error, stats, indexStatus
    }

    private enum Kind: String, Codable {
        case results, error, stats, ack, indexStatus
    }

    /// Search results for a completed query, with the corresponding query identifier.
    case results([SearchResult], queryID: String)
    /// An error occurred during request processing.
    case error(IPCError)
    /// Daemon statistics response.
    case stats(DaemonStats)
    /// Acknowledgment for commands that do not return data (e.g. config set, cancel).
    case ack
    /// Current index state and statistics.
    case indexStatus(DaemonIndexStatus)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .results(let res, let qid):
            try c.encode(Kind.results, forKey: .kind)
            try c.encode(res, forKey: .results)
            try c.encode(qid, forKey: .queryID)
        case .error(let err):
            try c.encode(Kind.error, forKey: .kind)
            try c.encode(err, forKey: .error)
        case .stats(let s):
            try c.encode(Kind.stats, forKey: .kind)
            try c.encode(s, forKey: .stats)
        case .ack:
            try c.encode(Kind.ack, forKey: .kind)
        case .indexStatus(let s):
            try c.encode(Kind.indexStatus, forKey: .kind)
            try c.encode(s, forKey: .indexStatus)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .results:
            let res = try c.decode([SearchResult].self, forKey: .results)
            let qid = try c.decode(String.self, forKey: .queryID)
            self = .results(res, queryID: qid)
        case .error:
            let err = try c.decode(IPCError.self, forKey: .error)
            self = .error(err)
        case .stats:
            let s = try c.decode(DaemonStats.self, forKey: .stats)
            self = .stats(s)
        case .ack:
            self = .ack
        case .indexStatus:
            let s = try c.decode(DaemonIndexStatus.self, forKey: .indexStatus)
            self = .indexStatus(s)
        }
    }
}

// MARK: - IPCFraming

/// Wire-framing helpers for the IPC protocol.
///
/// Uses a simple framing scheme: 4-byte big-endian length prefix followed by the
/// JSON payload. This allows the receiver to detect message boundaries on a stream
/// socket without relying on connection boundaries.
///
/// Debuggable via `nc -U ~/.deep-finder/ipc.sock` — the payload is human-readable JSON.
enum IPCFraming {
    /// Prepend a 4-byte big-endian UInt32 length header to `payload`.
    static func addLengthPrefix(to payload: Data) -> Data {
        var len = UInt32(payload.count).bigEndian
        var header = Data(bytes: &len, count: 4)
        header.append(payload)
        return header
    }

    /// Read the 4-byte length header, verify the payload is complete, return payload only.
    static func stripLengthPrefix(from data: Data) throws -> Data {
        guard data.count >= 4 else {
            throw IPCFramingError.insufficientHeader
        }
        let header = data.prefix(4)
        let declaredLen = UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) })
        let payloadStart = 4
        let payloadEnd = payloadStart + Int(declaredLen)
        guard data.count >= payloadEnd else {
            throw IPCFramingError.incompletePayload(expected: payloadEnd, actual: data.count)
        }
        return data.subdata(in: payloadStart..<payloadEnd)
    }

    /// Encode a Codable value and add length prefix in one step.
    static func encode<T: Codable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        return addLengthPrefix(to: payload)
    }

    /// Strip length prefix and decode a Codable value in one step.
    static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let payload = try stripLengthPrefix(from: data)
        return try JSONDecoder().decode(type, from: payload)
    }
}

// MARK: - IPCFramingError

/// Errors that can occur during IPC frame parsing.
enum IPCFramingError: Error, Sendable {
    /// Received fewer than 4 bytes — not enough for the length header.
    case insufficientHeader
    /// The declared payload length exceeds the available data.
    case incompletePayload(expected: Int, actual: Int)
}
