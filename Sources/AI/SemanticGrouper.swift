import Foundation

// MARK: - SemanticGroup

/// A named group of file IDs produced by semantic categorization.
///
/// Each group has a human-readable name (e.g. "Reports", "Design Files")
/// and the IDs of files belonging to that category.
struct SemanticGroup: Sendable, Equatable {
    /// Human-readable category name.
    let name: String
    /// File record IDs in this group.
    let fileIDs: [UInt32]
}

// MARK: - SemanticGrouper

/// Categorizes search results into semantic groups using an AI model provider.
///
/// For queries returning 20+ results, asks the AI to classify files into
/// meaningful categories based on file name, extension, and path metadata.
/// Always includes an "Other" catch-all group for files that don't fit
/// any named category.
///
/// **Graceful degradation**: Returns `nil` when:
/// - `provider` is `nil` (AI disabled) -- callers simply skip grouping
/// - Fewer than 20 results (too few to group meaningfully)
/// - AI call fails or returns unparseable output
/// In all cases, the caller continues with a flat result list.
///
/// REQ-3.0-08: Semantic Grouper
struct SemanticGrouper: Sendable {

    /// The AI provider used for categorization. `nil` means AI is disabled.
    let provider: (any AIModelProvider)?

    /// Minimum number of results required to trigger grouping.
    /// Below this threshold, grouping adds no value and is skipped.
    private static let minimumResults = 20

    init(provider: (any AIModelProvider)?) {
        self.provider = provider
    }

    /// Categorize search results into semantic groups.
    ///
    /// - Parameters:
    ///   - query: The user's original search query.
    ///   - results: Metadata summaries of the search results.
    ///   - ids: File record IDs corresponding to the results array.
    /// - Returns: An array of `SemanticGroup`, or `nil` if grouping is not applicable
    ///   (provider nil, too few results, mismatched arrays, or AI call failure).
    func group(query: String, results: [FileMetadataSummary], ids: [UInt32]) async -> [SemanticGroup]? {
        // No provider or insufficient results: gracefully return nil
        guard let provider, results.count >= Self.minimumResults else { return nil }
        guard results.count == ids.count else { return nil }

        // Build file listing with index for AI prompt
        let fileList = results.enumerated().map { (i, summary) in
            "[\(i)] \(summary.name) — \(summary.path)"
        }.joined(separator: "\n")

        let prompt = """
            Categorize these \(results.count) files into 2-5 semantic groups based on file name, \
            extension, and path. Each group needs a short name and the list of index numbers.

            Query: "\(query)"

            Files:
            \(fileList)

            Output format — one line per group, EXACTLY like this (no other text):
            GroupName: 0,3,5,7

            Every file index must appear in exactly one group. Include an "Other" group for \
            files that don't fit elsewhere.
            """

        let context = AIContext(
            query: query,
            resultMetadata: Array(results.prefix(50)),
            indexStats: .init(totalFiles: 0, queryResults: results.count)
        )

        do {
            var fullText = ""
            for try await chunk in provider.complete(prompt: prompt, context: context) {
                fullText += chunk
            }
            return parseGroups(from: fullText, totalIDs: ids)
        } catch {
            return nil
        }
    }

    // MARK: - Private

    /// Parse AI response into SemanticGroup array.
    ///
    /// Expected format: one line per group, "GroupName: idx1,idx2,idx3"
    /// Falls back to putting all IDs in "Other" if parsing fails.
    private func parseGroups(from text: String, totalIDs: [UInt32]) -> [SemanticGroup]? {
        var groups: [SemanticGroup] = []
        var assignedIndices = Set<Int>()

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Split on the first colon
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }

            let name = String(trimmed[..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            let indicesStr = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)

            guard !name.isEmpty else { continue }

            // Parse comma-separated indices
            let indices = indicesStr
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 >= 0 && $0 < totalIDs.count }

            guard !indices.isEmpty else { continue }

            let fileIDs = indices.map { totalIDs[$0] }
            groups.append(SemanticGroup(name: name, fileIDs: fileIDs))
            assignedIndices.formUnion(indices)
        }

        // Ensure all IDs are covered: add unassigned to "Other"
        let unassigned = (0..<totalIDs.count).filter { !assignedIndices.contains($0) }
        if !unassigned.isEmpty {
            let otherIDs = unassigned.map { totalIDs[$0] }
            // Check if "Other" group already exists
            if let otherIdx = groups.firstIndex(where: { $0.name.lowercased() == "other" }) {
                groups[otherIdx] = SemanticGroup(
                    name: "Other",
                    fileIDs: groups[otherIdx].fileIDs + otherIDs
                )
            } else {
                groups.append(SemanticGroup(name: "Other", fileIDs: otherIDs))
            }
        }

        // If we parsed nothing meaningful, return nil
        if groups.isEmpty { return nil }

        return groups
    }
}
