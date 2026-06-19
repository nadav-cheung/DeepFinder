// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// Codable message types that define the daemon IPC contract.
///
/// Every request (`IPCRequest`) and response (`IPCResponse`) is a Codable enum with a
/// `kind` discriminator and an embedded protocol version for forward compatibility.
/// Both CLI and GUI target the same daemon through these types, so changes here must
/// remain backward-compatible or bump `ipcProtocolVersion`.
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderFS
import DeepFinderPersist

/// Protocol version for forward compatibility.
///
/// Incremented when the wire format changes in a non-backward-compatible way.
/// Old CLI versions can detect incompatibility and prompt the user to upgrade.
/// This value is embedded in every ``IPCRequest`` encoding.
public let ipcProtocolVersion = 1

/// Maximum allowed query string length in characters.
///
/// Queries exceeding this limit are rejected before parsing to prevent
/// excessive memory allocation in the search pipeline. The IPC framing
/// layer enforces a 16 MB message limit; this guard rejects unreasonably
/// long queries much earlier, well before the search engine processes them.
public let maxQueryLength = Constants.IPC.maxQueryLength

// MARK: - IPCError

/// Fine-grained error types returned in IPC error responses.
public enum IPCError: Codable, Sendable, Equatable, Error {
    /// The daemon is still starting up and not ready to serve queries.
    case daemonNotReady
    /// The query could not be processed (syntax error, too long, etc.).
    case queryError(String)
    /// The request was malformed or missing required fields.
    case invalidRequest(String)
    /// The operation requires Full Disk Access or another permission.
    case permissionDenied(String)
    /// The client's protocol version is newer than what this daemon supports.
    case incompatibleProtocolVersion
}

// MARK: - DuplicateQueryStrategy

/// Strategy for duplicate file detection (REQ-1.5-06).
public enum DuplicateQueryStrategy: String, Codable, Sendable, Equatable, CaseIterable {
    /// Group by normalized file name.
    case name
    /// Group by file size.
    case size
    /// Group by SHA-256 content hash (caller pre-filters by size).
    case hash
    /// Find zero-byte files and empty directories.
    case empty
}

// MARK: - IPCRequest

/// All message types a client can send to the daemon.
public enum IPCRequest: Codable, Sendable, Equatable {
    /// Protocol version — included in every encoded message for forward compat.
    private enum CodingKeys: String, CodingKey {
        case ipcProtocolVersion
        case kind
        case query
        case limit
        case offset
        case queryID
        case key
        case value
        case strategy
        case bookmark
        case id
        case filterName
        case filterExpression
    }

    private enum Kind: String, Codable {
        case query, cancel, stats, configGet, configSet, indexStatus, duplicateQuery
        case bookmarkList, bookmarkSave, bookmarkDelete
        case filterList, filterSave, filterDelete
        case suggest, rescan
    }

    /// Execute a search query with optional result limit and offset.
    /// Offset is applied server-side (before limit truncation) so that
    /// pagination works correctly — unlike the previous client-side dropFirst
    /// which was defeated by the daemon's result cap.
    case query(_ query: String, limit: Int?, offset: Int? = nil)
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
    /// Find duplicate files using a given strategy (REQ-1.5-06).
    case duplicateQuery(strategy: DuplicateQueryStrategy)
    /// List all bookmarks (REQ-1.3-06).
    case bookmarkList
    /// Save a bookmark (REQ-1.3-06).
    case bookmarkSave(SearchBookmark)
    /// Delete a bookmark by ID (REQ-1.3-06).
    case bookmarkDelete(UUID)
    /// List all saved filter macros (REQ-1.3-06).
    case filterList
    /// Save a filter macro (REQ-1.3-06).
    case filterSave(name: String, expression: String)
    /// Delete a filter macro by name (REQ-1.3-06).
    case filterDelete(name: String)
    /// Request fuzzy suggestions for a query (REQ-1.0-03).
    case suggest(query: String)
    /// Trigger a full rescan of all paths (REQ-v0.0.1).
    case rescan

    // Custom Codable: encodes a `kind` discriminator + `ipcProtocolVersion` field.

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ipcProtocolVersion, forKey: .ipcProtocolVersion)
        switch self {
        case .query(let q, let lim, let off):
            try c.encode(Kind.query, forKey: .kind)
            try c.encode(q, forKey: .query)
            try c.encodeIfPresent(lim, forKey: .limit)
            try c.encodeIfPresent(off, forKey: .offset)
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
        case .duplicateQuery(let strategy):
            try c.encode(Kind.duplicateQuery, forKey: .kind)
            try c.encode(strategy, forKey: .strategy)
        case .bookmarkList:
            try c.encode(Kind.bookmarkList, forKey: .kind)
        case .bookmarkSave(let bm):
            try c.encode(Kind.bookmarkSave, forKey: .kind)
            try c.encode(bm, forKey: .bookmark)
        case .bookmarkDelete(let id):
            try c.encode(Kind.bookmarkDelete, forKey: .kind)
            try c.encode(id, forKey: .id)
        case .filterList:
            try c.encode(Kind.filterList, forKey: .kind)
        case .filterSave(let name, let expr):
            try c.encode(Kind.filterSave, forKey: .kind)
            try c.encode(name, forKey: .filterName)
            try c.encode(expr, forKey: .filterExpression)
        case .filterDelete(let name):
            try c.encode(Kind.filterDelete, forKey: .kind)
            try c.encode(name, forKey: .filterName)
        case .suggest(let query):
            try c.encode(Kind.suggest, forKey: .kind)
            try c.encode(query, forKey: .query)
        case .rescan:
            try c.encode(Kind.rescan, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)

        // Validate protocol version for forward compatibility.
        // Old clients (pre-version field) default to 1. Newer clients
        // sending a higher version than this daemon supports are rejected
        // with a clear error rather than risking silent misinterpretation.
        let clientVersion = try c.decodeIfPresent(Int.self, forKey: .ipcProtocolVersion) ?? 1
        guard clientVersion <= ipcProtocolVersion else {
            throw IPCError.incompatibleProtocolVersion
        }

        switch kind {
        case .query:
            let q = try c.decode(String.self, forKey: .query)
            guard q.count <= maxQueryLength else {
                throw IPCError.queryError(
                    "Query too long (\(q.count) chars, max \(maxQueryLength))"
                )
            }
            let lim = try c.decodeIfPresent(Int.self, forKey: .limit)
            let off = try c.decodeIfPresent(Int.self, forKey: .offset)
            self = .query(q, limit: lim, offset: off)
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
        case .duplicateQuery:
            let strategy = try c.decode(DuplicateQueryStrategy.self, forKey: .strategy)
            self = .duplicateQuery(strategy: strategy)
        case .bookmarkList:
            self = .bookmarkList
        case .bookmarkSave:
            let bm = try c.decode(SearchBookmark.self, forKey: .bookmark)
            self = .bookmarkSave(bm)
        case .bookmarkDelete:
            let id = try c.decode(UUID.self, forKey: .id)
            self = .bookmarkDelete(id)
        case .filterList:
            self = .filterList
        case .filterSave:
            let name = try c.decode(String.self, forKey: .filterName)
            let expr = try c.decode(String.self, forKey: .filterExpression)
            self = .filterSave(name: name, expression: expr)
        case .filterDelete:
            let name = try c.decode(String.self, forKey: .filterName)
            self = .filterDelete(name: name)
        case .suggest:
            let query = try c.decode(String.self, forKey: .query)
            self = .suggest(query: query)
        case .rescan:
            self = .rescan
        }
    }
}

// MARK: - DaemonStats

/// Runtime statistics reported by the daemon.
public struct DaemonStats: Codable, Sendable, Equatable {
    public init(totalFiles: Int, indexState: String, uptimeSeconds: Double, memoryUsageMB: Double, estimatedTotalFiles: Int? = nil) {
        self.totalFiles = totalFiles
        self.indexState = indexState
        self.uptimeSeconds = uptimeSeconds
        self.memoryUsageMB = memoryUsageMB
        self.estimatedTotalFiles = estimatedTotalFiles
    }
    /// Total number of files currently in the index.
    public let totalFiles: Int
    /// Current index state as a string (e.g. "live", "verifying", "polling").
    public let indexState: String
    /// Seconds since the daemon process started.
    public let uptimeSeconds: Double
    /// Approximate memory usage of the daemon process in megabytes.
    public let memoryUsageMB: Double
    /// Estimated total files on disk (from pre-scan count). `nil` while counting.
    public let estimatedTotalFiles: Int?
}

// MARK: - DaemonIndexStatus

/// Current state of the file index as reported by the daemon.
public struct DaemonIndexStatus: Codable, Sendable, Equatable {
    public init(state: String, filesIndexed: Int, lastScanDate: Date?) {
        self.state = state
        self.filesIndexed = filesIndexed
        self.lastScanDate = lastScanDate
    }
    /// Index state as a string (e.g. "stale", "verifying", "live", "polling").
    public let state: String
    /// Number of files currently indexed.
    public let filesIndexed: Int
    /// Timestamp of the last full scan, if available.
    public let lastScanDate: Date?
}

// MARK: - SavedFilter

/// A named filter macro for IPC transport (REQ-1.3-06).
public struct SavedFilter: Codable, Sendable, Equatable {
    public let name: String
    public let expression: String
}

// MARK: - IPCResponse

/// All message types the daemon can send back to a client.
public enum IPCResponse: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case kind, results, queryID, error, stats, indexStatus, duplicates
        case bookmarks, filters, suggestions, configValue
    }

    private enum Kind: String, Codable {
        case results, error, stats, ack, indexStatus, duplicates
        case bookmarks, filters, suggestions, configValue
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
    /// Duplicate file groups (REQ-1.5-06).
    case duplicates([DuplicateGroup])
    /// Bookmark list response (REQ-1.3-06).
    case bookmarks([SearchBookmark])
    /// Saved filter macro list response (REQ-1.3-06).
    case filters([SavedFilter])
    /// Fuzzy suggestions for a query (REQ-1.0-03).
    case suggestions([String])
    /// Config value response for configGet requests.
    case configValue(String)

    public func encode(to encoder: Encoder) throws {
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
        case .duplicates(let groups):
            try c.encode(Kind.duplicates, forKey: .kind)
            try c.encode(groups, forKey: .duplicates)
        case .bookmarks(let bms):
            try c.encode(Kind.bookmarks, forKey: .kind)
            try c.encode(bms, forKey: .bookmarks)
        case .filters(let fs):
            try c.encode(Kind.filters, forKey: .kind)
            try c.encode(fs, forKey: .filters)
        case .suggestions(let terms):
            try c.encode(Kind.suggestions, forKey: .kind)
            try c.encode(terms, forKey: .suggestions)
        case .configValue(let value):
            try c.encode(Kind.configValue, forKey: .kind)
            try c.encode(value, forKey: .configValue)
        }
    }

    public init(from decoder: Decoder) throws {
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
        case .duplicates:
            let groups = try c.decode([DuplicateGroup].self, forKey: .duplicates)
            self = .duplicates(groups)
        case .bookmarks:
            let bms = try c.decode([SearchBookmark].self, forKey: .bookmarks)
            self = .bookmarks(bms)
        case .filters:
            let fs = try c.decode([SavedFilter].self, forKey: .filters)
            self = .filters(fs)
        case .suggestions:
            let terms = try c.decode([String].self, forKey: .suggestions)
            self = .suggestions(terms)
        case .configValue:
            let value = try c.decode(String.self, forKey: .configValue)
            self = .configValue(value)
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
/// Debuggable via `nc -U ~/.deep-finder/session/ipc.sock` — the payload is human-readable JSON.
public enum IPCFraming {
    /// Prepend a 4-byte big-endian UInt32 length header to `payload`.
    public static func addLengthPrefix(to payload: Data) -> Data {
        var len = UInt32(payload.count).bigEndian
        var header = Data(bytes: &len, count: 4)
        header.append(payload)
        return header
    }

    /// Read the 4-byte length header, verify the payload is complete, return payload only.
    public static func stripLengthPrefix(from data: Data) throws -> Data {
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
    public static func encode<T: Codable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        return addLengthPrefix(to: payload)
    }

    /// Strip length prefix and decode a Codable value in one step.
    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let payload = try stripLengthPrefix(from: data)
        return try JSONDecoder().decode(type, from: payload)
    }
}

// MARK: - IPCFramingError

/// Errors that can occur during IPC frame parsing.
public enum IPCFramingError: Error, Sendable {
    /// Received fewer than 4 bytes — not enough for the length header.
    case insufficientHeader
    /// The declared payload length exceeds the available data.
    case incompletePayload(expected: Int, actual: Int)
}
