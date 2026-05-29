import Foundation

// MARK: - AutocompleteProvider

/// Provides filename and command autocomplete suggestions for the interactive REPL.
///
/// Uses the InMemoryIndex's Trie (via prefix search) to find matching filenames,
/// then deduplicates by name and sorts by frequency (how many distinct paths
/// share that filename).
actor AutocompleteProvider {

    /// The index used for filename lookups.
    private let index: InMemoryIndex

    /// REPL commands available for suggestion. Matches REPLCommand.allCases.
    private static let replCommands: [String] =
        REPLCommand.allCases.map { ":\($0.rawValue)" }

    init(index: InMemoryIndex) {
        self.index = index
    }

    // MARK: - Filename Suggestions

    /// Return autocomplete suggestions for a filename prefix.
    ///
    /// - Parameters:
    ///   - prefix: The user's typed prefix (case-insensitive, NFC-normalized internally).
    ///   - limit: Maximum number of suggestions to return.
    /// - Returns: Unique filenames sorted by descending frequency (count of
    ///   distinct paths sharing that name). Each filename appears at most once.
    func suggest(prefix: String, limit: Int = 10) async -> [String] {
        let normalized = prefix
            .precomposedStringWithCanonicalMapping
            .lowercased()

        // Empty prefix: return most frequent filenames across all records
        guard !normalized.isEmpty else {
            let all = await index.allRecords()
            var nameFrequency: [String: Int] = [:]
            for record in all {
                nameFrequency[record.name, default: 0] += 1
            }
            let sorted = nameFrequency.sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            return Array(sorted.prefix(limit).map(\.key))
        }

        // Non-empty prefix: query the index
        let results = await index.search(query: normalized)

        // Group by normalized name, collect distinct original names with frequency
        var nameFrequency: [String: Int] = [:]   // key = original name
        for record in results {
            nameFrequency[record.name, default: 0] += 1
        }

        // Sort by frequency descending, then alphabetically for stability
        let sorted = nameFrequency.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }

        return Array(sorted.prefix(limit).map(\.key))
    }

    // MARK: - Command Suggestions

    /// Return REPL commands matching the given prefix.
    ///
    /// - Parameter prefix: The typed prefix, e.g. ":st". Case-insensitive.
    /// - Returns: Commands starting with the prefix, e.g. [":stats"].
    nonisolated func suggestCommands(prefix: String) -> [String] {
        let lowered = prefix.lowercased()
        return Self.replCommands.filter { $0.lowercased().hasPrefix(lowered) }
    }
}
