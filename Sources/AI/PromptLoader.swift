// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

/// Loads externalized system prompts from the app bundle.
///
/// Prompts are stored as .txt files under Sources/AI/Prompts/.
/// At build time they are copied into the app bundle resources.
///
/// Fallback: if a prompt file cannot be loaded, callers should use
/// their inline default prompt string.
public struct PromptLoader: Sendable {

    /// Load a prompt by logical name (without .txt extension).
    ///
    /// Returns the prompt content, or nil if not found.
    public static func load(name: String) -> String? {
        // Search main bundle and module bundle (for tests)
        let bundles = [Bundle.main]
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: "txt"),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }
        return nil
    }
}
