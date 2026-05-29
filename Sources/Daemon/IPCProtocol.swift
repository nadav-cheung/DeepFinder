import Foundation

/// Protocol version for forward compatibility. Old CLI can detect new daemon version.
let ipcProtocolVersion = 1

// MARK: - IPCError

/// Fine-grained error types for IPC responses.
enum IPCError: Codable, Sendable, Equatable {
    case daemonNotReady
    case queryError(String)
    case invalidRequest(String)
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

    case query(_ query: String, limit: Int?)
    case cancel(queryID: String)
    case stats
    case configGet(key: String?)
    case configSet(key: String, value: String)
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

struct DaemonStats: Codable, Sendable, Equatable {
    let totalFiles: Int
    let indexState: String
    let uptimeSeconds: Double
    let memoryUsageMB: Double
}

// MARK: - DaemonIndexStatus

struct DaemonIndexStatus: Codable, Sendable, Equatable {
    let state: String
    let filesIndexed: Int
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

    case results([SearchResult], queryID: String)
    case error(IPCError)
    case stats(DaemonStats)
    case ack
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

/// Wire-framing helpers: 4-byte big-endian length prefix + payload.
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

enum IPCFramingError: Error, Sendable {
    case insufficientHeader
    case incompletePayload(expected: Int, actual: Int)
}
