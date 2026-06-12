// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderDaemon

// MARK: - SearchURL

/// Represents a parsed `deepfinder://` URL.
///
/// Currently supports:
/// - `deepfinder://search?q=keyword&limit=20&filter=ext:pdf`
///
/// Invalid or unrecognized URLs resolve to `nil` via ``parse(_:)``.
public enum SearchURL: Sendable, Equatable {
    /// A search request with query string, optional result limit, and optional filter expression.
    case search(query: String, limit: Int?, filter: String?)

    // MARK: - Parsing

    /// Parse a URL into a ``SearchURL``, or return `nil` if the URL is invalid
    /// or does not conform to the `deepfinder://` scheme.
    ///
    /// - Parameter url: The URL to parse.
    /// - Returns: A ``SearchURL`` value, or `nil` for invalid/unrecognized URLs.
    public static func parse(_ url: URL) -> SearchURL? {
        // Must have the correct scheme and host.
        guard url.scheme == Product.urlScheme, url.host == "search" else {
            return nil
        }

        // Extract query items.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems, !queryItems.isEmpty else {
            return nil
        }

        // Extract required "q" parameter.
        guard let qValue = queryItems.first(where: { $0.name == "q" })?.value,
              !qValue.isEmpty else {
            return nil
        }

        // Extract optional "limit" parameter (must be positive integer).
        let limit: Int? = queryItems
            .first(where: { $0.name == "limit" })
            .flatMap { item -> Int? in
                guard let raw = item.value, let parsed = Int(raw), parsed > 0 else {
                    return nil
                }
                return parsed
            }

        // Extract optional "filter" parameter.
        let filter: String? = queryItems
            .first(where: { $0.name == "filter" })
            .flatMap { item -> String? in
                guard let raw = item.value, !raw.isEmpty else {
                    return nil
                }
                return raw
            }

        return .search(query: qValue, limit: limit, filter: filter)
    }
}
