// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

/// Information about a registered AI provider.
public struct ProviderInfo: Sendable, Equatable {
    /// Config key value (e.g., "qwen", "deepseek")
    public let name: String
    /// Human-readable display name (e.g., "Qwen Cloud (通义千问)")
    public let displayName: String
    /// Uses OpenAI-compatible chat completions API format
    public let isOpenAICompatible: Bool
    /// Has a companion embedding API
    public let hasEmbeddingAPI: Bool
    /// Default endpoint URL (nil for custom/non-OAI)
    public let defaultEndpoint: String?
    /// Default model name
    public let defaultModel: String
    /// Requires custom endpoint/model configuration
    public let requiresCustomConfig: Bool
}

/// Registry of all supported AI providers with auto-routing logic.
///
/// Adding a new provider:
/// 1. Add a case to the `allProviders` array below
/// 2. If OpenAI-compatible, no code changes needed — uses ``OpenAICompatibleProvider``
/// 3. If custom protocol, add a new Provider implementation (e.g., AnthropicProvider)
/// 4. ``ProviderRegistry/instantiate(model:apiKey:httpClient:customEndpoint:customModelName:)``
///    handles the mapping
public struct ProviderRegistry: Sendable {

    /// All supported LLM providers, in display order.
    public static let allProviders: [ProviderInfo] = [
        // OpenAI-compatible providers
        ProviderInfo(name: "qwen", displayName: "Qwen Cloud (通义千问)",
                     isOpenAICompatible: true, hasEmbeddingAPI: true,
                     defaultEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                     defaultModel: "qwen3.6-plus", requiresCustomConfig: false),
        ProviderInfo(name: "zhipu", displayName: "智谱 GLM",
                     isOpenAICompatible: true, hasEmbeddingAPI: true,
                     defaultEndpoint: "https://open.bigmodel.cn/api/paas/v4",
                     defaultModel: "glm-5.5-plus", requiresCustomConfig: false),
        ProviderInfo(name: "deepseek", displayName: "DeepSeek Cloud",
                     isOpenAICompatible: true, hasEmbeddingAPI: false,
                     defaultEndpoint: "https://api.deepseek.com",
                     defaultModel: "deepseek-chat", requiresCustomConfig: false),
        ProviderInfo(name: "openai", displayName: "OpenAI",
                     isOpenAICompatible: true, hasEmbeddingAPI: true,
                     defaultEndpoint: "https://api.openai.com/v1",
                     defaultModel: "gpt-5.1", requiresCustomConfig: false),
        ProviderInfo(name: "moonshot", displayName: "Moonshot Kimi",
                     isOpenAICompatible: true, hasEmbeddingAPI: false,
                     defaultEndpoint: "https://api.moonshot.cn/v1",
                     defaultModel: "moonshot-v1-auto", requiresCustomConfig: false),
        ProviderInfo(name: "minimax", displayName: "MiniMax",
                     isOpenAICompatible: true, hasEmbeddingAPI: false,
                     defaultEndpoint: "https://api.minimax.chat/v1",
                     defaultModel: "minimax-text-01", requiresCustomConfig: false),
        ProviderInfo(name: "custom", displayName: "Custom (OpenAI-compatible)",
                     isOpenAICompatible: true, hasEmbeddingAPI: false,
                     defaultEndpoint: nil, defaultModel: "",
                     requiresCustomConfig: true),

        // Custom API providers (non-OpenAI-compatible)
        ProviderInfo(name: "anthropic", displayName: "Claude (Anthropic)",
                     isOpenAICompatible: false, hasEmbeddingAPI: false,
                     defaultEndpoint: "https://api.anthropic.com/v1",
                     defaultModel: "claude-opus-4-5-20251101", requiresCustomConfig: false),
        ProviderInfo(name: "gemini", displayName: "Google Gemini",
                     isOpenAICompatible: false, hasEmbeddingAPI: true,
                     defaultEndpoint: "https://generativelanguage.googleapis.com/v1beta",
                     defaultModel: "gemini-2.5-pro", requiresCustomConfig: false),

        // On-device (must be last — fallback)
        ProviderInfo(name: "apple", displayName: "Apple On-Device",
                     isOpenAICompatible: false, hasEmbeddingAPI: false,
                     defaultEndpoint: nil, defaultModel: "apple-on-device-3b",
                     requiresCustomConfig: false),
    ]

    /// Priority order for auto-routing. First available wins. Apple last (region-restricted fallback).
    public static let autoPriority: [String] = [
        "qwen", "zhipu", "deepseek", "openai", "moonshot", "minimax", "apple"
    ]

    /// All cloud providers that have embedding APIs.
    public static let embeddingProviders: [ProviderInfo] = allProviders.filter {
        $0.hasEmbeddingAPI && $0.isOpenAICompatible
    }

    /// Look up provider info by config name.
    public func providerInfo(for name: String) -> ProviderInfo? {
        Self.allProviders.first { $0.name == name }
    }

    /// Instantiate an AIModelProvider from config.
    ///
    /// Returns nil when model is "off", provider is unknown, or required config is missing.
    public func instantiate(
        model: String,
        apiKey: String,
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        customEndpoint: String? = nil,
        customModelName: String? = nil
    ) -> (any AIModelProvider)? {
        guard model != "off", let info = providerInfo(for: model) else { return nil }

        if info.isOpenAICompatible {
            let endpointStr = info.name == "custom"
                ? (customEndpoint ?? "")
                : (info.defaultEndpoint ?? "")
            guard let endpoint = URL(string: endpointStr + "/chat/completions") else { return nil }
            let modelName = info.name == "custom"
                ? (customModelName ?? "")
                : info.defaultModel
            guard !modelName.isEmpty else { return nil }
            return OpenAICompatibleProvider(
                name: info.name,
                endpoint: endpoint,
                apiKey: apiKey,
                model: modelName,
                httpClient: httpClient
            )
        }

        // Non-OAI providers (anthropic, gemini, apple) are handled by their
        // respective factory methods in the caller.
        return nil
    }
}
