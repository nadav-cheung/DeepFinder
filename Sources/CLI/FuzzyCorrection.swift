import Foundation

// MARK: - FuzzyCorrector

/// Suggests corrections for misspelled search queries based on known file names/words.
///
/// Uses Levenshtein distance with early termination to find the closest known term
/// within a configurable edit distance threshold. All comparisons are case-insensitive.
struct FuzzyCorrector {

    /// Known terms (lowercased) derived from indexed file names and extensions.
    private let terms: [String]

    /// Precomputed lengths for early termination optimization.
    private let termLengths: [Int]

    /// Build the corrector from a set of known filenames or words.
    ///
    /// Terms are lowercased internally for case-insensitive matching.
    init(knownTerms: Set<String>) {
        self.terms = knownTerms.map { $0.lowercased() }
        self.termLengths = self.terms.map { $0.count }
    }

    /// Find the closest known term to the given query.
    ///
    /// - Parameters:
    ///   - query: The user's (possibly misspelled) query.
    ///   - maxDistance: Maximum Levenshtein distance to consider. Defaults to 2.
    /// - Returns: The best matching known term (original casing from `knownTerms`),
    ///   or `nil` if no match within `maxDistance` or the query is an exact match.
    func suggest(for query: String, maxDistance: Int = 2) -> String? {
        let lowered = query.lowercased()
        guard !lowered.isEmpty else { return nil }

        let queryLen = lowered.count
        var bestTerm: String?
        var bestDist = maxDistance + 1

        for i in terms.indices {
            let termLen = termLengths[i]

            // Early termination: length difference alone exceeds maxDistance
            let lenDiff = abs(queryLen - termLen)
            if lenDiff > maxDistance { continue }

            let dist = levenshtein(lowered, terms[i], limit: bestDist)

            // Exact match means no correction needed
            if dist == 0 { return nil }

            if dist < bestDist {
                bestDist = dist
                bestTerm = terms[i]
            }
        }

        guard bestDist <= maxDistance else { return nil }
        return bestTerm
    }

    // MARK: - Levenshtein Distance

    /// Compute Levenshtein distance between two strings with a pruning limit.
    ///
    /// Uses the classic Wagner-Fischer algorithm with a single-row optimization.
    /// The `limit` parameter enables early exit: once the minimum possible distance
    /// in the current row exceeds `limit`, computation stops.
    ///
    /// - Parameters:
    ///   - a: First string.
    ///   - b: Second string.
    ///   - limit: Upper bound on distance; returns early if exceeded.
    /// - Returns: The edit distance, or `limit + 1` if it would exceed `limit`.
    private func levenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        if a == b { return 0 }

        let aChars = Array(a.unicodeScalars)
        let bChars = Array(b.unicodeScalars)
        let aLen = aChars.count
        let bLen = bChars.count

        // Empty string cases
        if aLen == 0 { return bLen > limit ? limit + 1 : bLen }
        if bLen == 0 { return aLen > limit ? limit + 1 : aLen }

        // Single-row DP: row[j] = edit distance between a[0..<i] and b[0..<j]
        var row = Array(0...bLen)

        for i in 0..<aLen {
            var prev = row[0]
            row[0] = i + 1

            // Track minimum value in this row for early termination
            var rowMin = row[0]

            for j in 0..<bLen {
                let cost = aChars[i] == bChars[j] ? 0 : 1
                let newVal = min(
                    row[j] + 1,       // deletion
                    row[j + 1] + 1,   // insertion
                    prev + cost       // substitution
                )
                prev = row[j + 1]
                row[j + 1] = newVal
                if newVal < rowMin { rowMin = newVal }
            }

            // Early termination: all future distances will be >= rowMin
            if rowMin > limit { return limit + 1 }
        }

        return row[bLen]
    }
}
