// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// Reads plain text from the macOS pasteboard for clipboard-triggered search.
///
/// Only captures .string content (ignores images/files), produces a truncated
/// preview for UI display, and never auto-searches or records history.
// Sources/AI/ClipboardSearch.swift
import AppKit
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

// MARK: - ClipboardContent

/// Represents text content detected on the system pasteboard.
///
/// REQ-3.0-16: Detects clipboard text (ignores images/files), provides a
/// truncated preview for UI display, and requires explicit user action
/// to trigger the search (no auto-search, no history recording).
public struct ClipboardContent: Sendable, Equatable {
    /// The full text content from the pasteboard.
    public let text: String
    /// A truncated preview: first `maxLength` characters with "..." appended
    /// if the text exceeds the limit.
    public let preview: String
}

// MARK: - ClipboardSearch

/// Reads text content from the macOS pasteboard for clipboard-based search.
///
/// **Privacy**: Only reads plain text (`.string` type), ignoring images,
/// file URLs, and other non-text content. Returns nil for empty strings
/// or when no text is present. No clipboard content is logged or stored
/// beyond the search session.
///
/// **User control**: REQ-3.0-16 requires explicit user action to trigger
/// the search (no auto-search, no history recording). The truncated preview
/// is for UI display only.
public enum ClipboardSearch: Sendable {

    /// Reads the current text content from the given pasteboard.
    ///
    /// - Parameter pasteboard: The `NSPasteboard` to read from.
    ///   Defaults to `NSPasteboard.general` for convenience in production code.
    /// - Returns: A `ClipboardContent` with the full text and truncated preview,
    ///   or `nil` if the pasteboard contains no text, only non-text content,
    ///   or an empty string.
    public static func detectClipboardText(pasteboard: NSPasteboard = .general) -> ClipboardContent? {
        guard let text = pasteboard.string(forType: .string) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let preview = truncateToPreview(trimmed)
        return ClipboardContent(text: trimmed, preview: preview)
    }

    /// Truncates text to the given maximum length, appending "..." if truncated.
    ///
    /// - Parameters:
    ///   - text: The text to potentially truncate.
    ///   - maxLength: Maximum number of characters to keep (default 100).
    /// - Returns: The original text if it fits, or `text.prefix(maxLength) + "..."`.
    public static func truncateToPreview(_ text: String, maxLength: Int = 100) -> String {
        if text.count <= maxLength {
            return text
        }
        return String(text.prefix(maxLength)) + "..."
    }
}
