import Foundation
import Testing
@testable import DeepFinderAI

@Suite("ProviderRegistry")
struct ProviderRegistryTests {

    @Test("resolve known provider returns correct info")
    func resolveKnownProvider() {
        let registry = ProviderRegistry()
        let info = registry.providerInfo(for: "qwen")
        #expect(info != nil)
        #expect(info?.name == "qwen")
        #expect(info?.displayName == "Qwen Cloud (通义千问)")
        #expect(info?.isOpenAICompatible ?? false)
        #expect(info?.hasEmbeddingAPI ?? false)
    }

    @Test("resolve unknown provider returns nil")
    func resolveUnknownProviderReturnsNil() {
        let registry = ProviderRegistry()
        #expect(registry.providerInfo(for: "nonexistent") == nil)
    }

    @Test("resolve custom returns custom info with requiresConfig")
    func resolveCustomReturnsCustomInfo() {
        let registry = ProviderRegistry()
        let info = registry.providerInfo(for: "custom")
        #expect(info != nil)
        #expect(info?.requiresCustomConfig ?? false)
    }

    @Test("all providers have unique names")
    func allProvidersHaveUniqueNames() {
        let names = ProviderRegistry.allProviders.map { $0.name }
        #expect(Set(names).count == names.count)
    }

    @Test("auto priority has apple last")
    func autoPriorityHasAppleLast() {
        #expect(ProviderRegistry.autoPriority.last == "apple")
        #expect(ProviderRegistry.autoPriority.first == "qwen")
    }

    @Test("openAI compatible providers include expected set")
    func openAICompatibleProvidersIncludeExpectedSet() {
        let oaiProviders = ProviderRegistry.allProviders
            .filter { $0.isOpenAICompatible }
            .map { $0.name }
        #expect(oaiProviders.contains("qwen"))
        #expect(oaiProviders.contains("deepseek"))
        #expect(oaiProviders.contains("zhipu"))
        #expect(oaiProviders.contains("openai"))
        #expect(oaiProviders.contains("moonshot"))
        #expect(oaiProviders.contains("minimax"))
        #expect(oaiProviders.contains("custom"))
    }

    @Test("custom API providers include anthropic, gemini, apple")
    func customAPIProvidersIncludeExpected() {
        let customAPI = ProviderRegistry.allProviders
            .filter { !$0.isOpenAICompatible }
            .map { $0.name }
        #expect(customAPI.contains("anthropic"))
        #expect(customAPI.contains("gemini"))
        #expect(customAPI.contains("apple"))
    }

    @Test("embedding providers are subset of all providers")
    func embeddingProvidersAreSubset() {
        let allNames = Set(ProviderRegistry.allProviders.map { $0.name })
        let embeddingNames = Set(ProviderRegistry.embeddingProviders.map { $0.name })
        #expect(embeddingNames.isSubset(of: allNames))
        #expect(embeddingNames.contains("qwen"))
        #expect(embeddingNames.contains("zhipu"))
    }

    @Test("instantiate returns nil for unknown model")
    func instantiateUnknownReturnsNil() {
        let registry = ProviderRegistry()
        #expect(registry.instantiate(model: "nonexistent", apiKey: "sk-test") == nil)
    }

    @Test("instantiate returns nil for off")
    func instantiateOffReturnsNil() {
        let registry = ProviderRegistry()
        #expect(registry.instantiate(model: "off", apiKey: "sk-test") == nil)
    }

    @Test("ProviderInfo is Equatable")
    func providerInfoIsEquatable() {
        let a = ProviderInfo(name: "test", displayName: "Test", isOpenAICompatible: true,
                              hasEmbeddingAPI: false, defaultEndpoint: nil,
                              defaultModel: "m1", requiresCustomConfig: false)
        let b = ProviderInfo(name: "test", displayName: "Test", isOpenAICompatible: true,
                              hasEmbeddingAPI: false, defaultEndpoint: nil,
                              defaultModel: "m1", requiresCustomConfig: false)
        #expect(a == b)
    }
}
