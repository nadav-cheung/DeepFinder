// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex

/// Lazily extracts and caches media metadata on demand.
///
/// Wraps a ``MetadataExtractorRegistry`` with a per-path cache. Extraction runs on this
/// actor's executor (off the caller's thread), so GUI callers can `await` it from a
/// SwiftUI `.task` modifier without blocking the main thread.
///
/// **Caching**: successful extractions are cached by absolute file path for the lifetime
/// of the loader, so re-displaying a file's detail is instant. Failed or unsupported
/// extractions (`nil`) are deliberately **not** cached, allowing a later retry (e.g. after
/// a transient I/O failure). Per project policy ("memory is not a constraint"), the cache
/// is unbounded — appropriate for a search-detail use case where the working set is small.
///
/// **On-demand model**: metadata is extracted when a user inspects a file, NOT during
/// scanning. This keeps the index fast (speed is the #1 priority). As a consequence the
/// extracted metadata is not persisted and not queryable through the search filter
/// pipeline — see ``MetadataExtractorRegistry`` for the integration status.
public actor MetadataLoader {

    /// The registry used to dispatch extraction by file extension.
    private let registry: MetadataExtractorRegistry

    /// Absolute file path → extracted metadata. Successful extractions only.
    private var cache: [String: ExtractedMetadata] = [:]

    /// Create a loader backed by the given registry.
    public init(registry: MetadataExtractorRegistry) {
        self.registry = registry
    }

    /// Extract (or return cached) metadata for the file at `url`.
    ///
    /// - Parameters:
    ///   - url: The file URL to inspect.
    ///   - fileExtension: The extension to dispatch on. If `nil` or empty, the extension
    ///     is derived from `url.pathExtension`. Matching is case-insensitive.
    /// - Returns: The extracted metadata, or `nil` if the extension is unsupported or
    ///   extraction failed.
    public func metadata(for url: URL, fileExtension ext: String?) async -> ExtractedMetadata? {
        let path = url.path
        if let cached = cache[path] {
            return cached
        }
        let resolvedExt: String
        if let ext, !ext.isEmpty {
            resolvedExt = ext.lowercased()
        } else {
            resolvedExt = url.pathExtension.lowercased()
        }
        guard let extracted = await registry.extract(url: url, extension: resolvedExt) else {
            return nil
        }
        cache[path] = extracted
        return extracted
    }

    /// Return cached metadata for a path without triggering extraction.
    public func cachedMetadata(forPath path: String) -> ExtractedMetadata? {
        cache[path]
    }

    /// Remove all cached entries.
    public func clearCache() {
        cache.removeAll()
    }
}

public extension MetadataLoader {
    /// Process-wide default loader using ``MetadataExtractorRegistry/default``.
    ///
    /// Shared so that metadata cached while inspecting one file is reused if the user
    /// revisits it. The cache is per-path and unbounded (see ``MetadataLoader`` notes).
    static let shared = MetadataLoader(registry: .default)
}
