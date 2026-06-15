// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderDaemon

/// Detects duplicate-finder commands in a raw query string and maps them to the
/// IPC `DuplicateQueryStrategy`.
///
/// The duplicate-finder backend (`DuplicateFinder`) and IPC transport
/// (`.duplicateQuery(strategy:)` / `.duplicates`) are fully implemented, but a
/// query like `dupe:` must be routed to `.duplicateQuery` rather than treated as
/// a plain substring search. This helper performs that detection so both
/// single-shot and REPL query paths can dispatch correctly.
public enum DuplicateCommand {

    /// Map a raw query to a duplicate strategy, or `nil` if it is a regular search.
    ///
    /// Accepts the bare keyword (`dupe`) or the colon form (`dupe:`, `dupe: ext:pdf`);
    /// matching is case-insensitive. Trailing tokens are currently ignored — the
    /// duplicate scan runs across the whole index (sub-filtering is a future
    /// enhancement).
    public static func detect(_ query: String) -> DuplicateQueryStrategy? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        func matches(_ keyword: String) -> Bool {
            trimmed == keyword || trimmed.hasPrefix(keyword + ":") || trimmed.hasPrefix(keyword + " ")
        }

        // Check longer keywords first so "sizedupe"/"hashdupe" are not shadowed.
        if matches("sizedupe") { return .size }
        if matches("hashdupe") { return .hash }
        if matches("dupe") { return .name }
        if matches("empty") { return .empty }
        return nil
    }
}
