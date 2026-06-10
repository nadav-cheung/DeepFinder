import Foundation
import DeepFinderIndex

// MARK: - ContentSearchProvider

/// A search provider that scans file *contents* for a query string.
///
/// Unlike `FileIndexProvider` (which matches filenames), this provider reads
/// file contents line-by-line and yields results for files whose content
/// contains the query text.
///
/// Only text files (by extension whitelist) are scanned. Binary files are
/// skipped. Encoding is auto-detected via BOM (UTF-8, UTF-16 LE, UTF-16 BE).
///
/// Results are returned as `SearchResult` with `.substring` match type and a
/// score proportional to the number of content matches found. Line-level match
/// details can be retrieved via `contentMatches(for:)`.
public actor ContentSearchProvider: SearchProvider {

    // MARK: - Properties

    public let providerID = "content-search"

    private let index: InMemoryIndex
    private var storedMatches: [UInt32: [ContentMatch]] = [:]

    // MARK: - Init

    /// Create a content search provider backed by the given index.
    ///
    /// - Parameter index: The in-memory index to use for enumerating candidate files.
    public init(index: InMemoryIndex) {
        self.index = index
    }

    // MARK: - SearchProvider

    public func search(query: SearchQuery) async -> SearchResultSequence {
        let results = await performSearch(query: query)
        return SearchResultSequence(results)
    }

    public func prepare() async {
        // No-op: content scanning reads files on demand.
    }

    public func cancel(queryID: String) async {
        // MVP: scan completes synchronously per file, nothing to cancel.
    }

    // MARK: - Public API

    /// Retrieve line-level match details for a previously found file.
    ///
    /// Returns `nil` if the file was not part of the last search results.
    public func contentMatches(for recordID: UInt32) -> [ContentMatch]? {
        storedMatches[recordID]
    }

    /// Clear stored match details (e.g. between searches).
    public func clearMatches() {
        storedMatches.removeAll(keepingCapacity: true)
    }

    // MARK: - Internal

    private func performSearch(query: SearchQuery) async -> [SearchResult] {
        guard !query.normalizedQuery.isEmpty else { return [] }

        // Get all indexed records, filter to text files only
        let allRecords = await index.allRecords()
        let candidates = allRecords
            .filter { record in
                !record.isDirectory && TextFileExtensions.isTextFile(record.extension)
            }
            .prefix(Constants.ContentScanner.maxCandidates)  // REQ-1.4-04: 10k candidate cap

        // Clear previous match storage
        storedMatches.removeAll(keepingCapacity: true)

        let scanOptions = ScanOptions(caseSensitive: false)
        var results: [SearchResult] = []
        var totalBytesRead: Int64 = 0
        let ioBudget = Constants.ContentScanner.maxTotalIO  // 512 MB

        for record in candidates {
            // REQ-1.4-04: stop scanning when I/O budget is exhausted
            if totalBytesRead >= ioBudget { break }

            // Skip files exceeding the per-file size limit
            guard record.size <= Constants.ContentScanner.maxFileSize else { continue }

            let matches = ContentScanner.scan(
                fileAtPath: record.path,
                query: query.normalizedQuery,
                options: scanOptions
            )

            // Track I/O: approximate bytes read per file
            totalBytesRead += record.size

            guard !matches.isEmpty else { continue }

            // Store line-level details
            storedMatches[record.id] = matches

            // Score: 1.0 for first match, decays with more matches.
            let matchCount = matches.count
            let score = min(1.0, 0.5 + 0.1 * Double(matchCount))

            results.append(SearchResult(
                record: record,
                providerID: providerID,
                score: score,
                matchType: .substring
            ))
        }

        return results
    }
}
