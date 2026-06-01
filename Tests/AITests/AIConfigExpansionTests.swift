import Foundation
import Testing
@testable import DeepFinder

@Suite("AIConfigExpansion")
struct AIConfigExpansionTests {

    @Test("new defaults are present")
    func newDefaultsPresent() {
        #expect(AIConfig.defaults["ai.cloudFallback"] == "true")
        #expect(AIConfig.defaults["ai.embeddingModel"] == "nlcontextual")
        #expect(AIConfig.defaults["ai.cacheTTL"] == "300")
        #expect(AIConfig.defaults["ai.customEndpoint"] == "")
        #expect(AIConfig.defaults["ai.customModelName"] == "")
        #expect(AIConfig.defaults["ai.customAPIKey"] == "")
    }

    @Test("embeddingModelName returns configured value")
    func embeddingModelNameConfigured() {
        #expect(AIConfig.embeddingModelName(config: ["ai.embeddingModel": "qwen"]) == "qwen")
    }

    @Test("embeddingModelName returns default")
    func embeddingModelNameDefault() {
        #expect(AIConfig.embeddingModelName(config: [:]) == "nlcontextual")
    }

    @Test("cacheTTL returns configured value")
    func cacheTTLConfigured() {
        #expect(AIConfig.cacheTTL(config: ["ai.cacheTTL": "600"]) == 600)
    }

    @Test("cacheTTL defaults to 300")
    func cacheTTLDefault() {
        #expect(AIConfig.cacheTTL(config: [:]) == 300)
    }

    @Test("cacheTTL clamps to minimum 60")
    func cacheTTLClampMin() {
        #expect(AIConfig.cacheTTL(config: ["ai.cacheTTL": "30"]) == 60)
    }

    @Test("cacheTTL clamps to maximum 3600")
    func cacheTTLClampMax() {
        #expect(AIConfig.cacheTTL(config: ["ai.cacheTTL": "99999"]) == 3600)
    }

    @Test("cloudFallbackEnabled defaults to true")
    func cloudFallbackEnabledDefault() {
        #expect(AIConfig.cloudFallbackEnabled(config: [:]) == true)
    }

    @Test("custom endpoint and model name accessors")
    func customConfigAccessors() {
        let config = [
            "ai.customEndpoint": "https://api.example.com/v1",
            "ai.customModelName": "my-model",
        ]
        #expect(AIConfig.customEndpoint(config: config) == "https://api.example.com/v1")
        #expect(AIConfig.customModelName(config: config) == "my-model")
    }

    @Test("all new keys in AIConfigKey enum")
    func allNewKeysInEnum() {
        let allCases = AIConfigKey.allCases.map { $0.rawValue }
        #expect(allCases.contains("cloudFallback"))
        #expect(allCases.contains("embeddingModel"))
        #expect(allCases.contains("cacheTTL"))
        #expect(allCases.contains("customEndpoint"))
        #expect(allCases.contains("customModelName"))
        #expect(allCases.contains("customAPIKey"))
    }
}
