import Foundation

// MARK: - QwenProvider Re-export

/// Qwen provider is an `OpenAICompatibleProvider` configured for the Qwen/DashScope endpoint.
///
/// The shared implementation lives in `DeepSeekProvider.swift` alongside `DeepSeekProvider`.
/// This file exists for documentation clarity and to ensure the module exports the type.
///
/// **Privacy**: Same as all cloud providers -- only file metadata (``FileMetadataSummary``)
/// is sent to the Qwen API, never file contents. All AI features are opt-in via ``AIConfig``.
///
/// REQ-3.0-04: Qwen (千问) integration.
///
/// Usage:
/// ```swift
/// let provider = QwenProvider.qwen(apiKey: "sk-...")
/// // or equivalently:
/// let provider = QwenProvider(name: "qwen", endpoint: ..., apiKey: "sk-...", model: "qwen-plus")
/// ```
