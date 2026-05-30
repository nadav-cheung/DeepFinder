import Foundation
import Testing
@testable import DeepFinder

@Suite("AIConfig")
struct AIConfigTests {

    @Test("All defaults are present")
    func allDefaultsPresent() {
        let defaults = AIConfig.defaults
        #expect(defaults["ai.enabled"] == "false")
        #expect(defaults["ai.model"] == "off")
        #expect(defaults["ai.sendMetadata"] == "false")
        #expect(defaults["ai.pathAnonymization"] == "true")
        #expect(defaults["ai.localVision"] == "true")
        #expect(defaults["ai.apiKey"] == "")
    }

    @Test("AI is off by default")
    func disabledByDefault() {
        #expect(AIConfig.isEnabled(config: AIConfig.defaults) == false)
    }

    @Test("isEnabled reads from config correctly")
    func isEnabledReadsConfig() {
        #expect(AIConfig.isEnabled(config: ["ai.enabled": "true"]) == true)
        #expect(AIConfig.isEnabled(config: ["ai.enabled": "false"]) == false)
        #expect(AIConfig.isEnabled(config: [:]) == false)
    }

    @Test("modelName returns correct value")
    func modelNameReturnsCorrect() {
        #expect(AIConfig.modelName(config: ["ai.model": "deepseek"]) == "deepseek")
        #expect(AIConfig.modelName(config: ["ai.model": "qwen"]) == "qwen")
        #expect(AIConfig.modelName(config: ["ai.model": "off"]) == "off")
        #expect(AIConfig.modelName(config: [:]) == "off")
    }

    @Test("AIConfigKey has all required cases")
    func configKeyAllCases() {
        let expected: Set<String> = [
            "enabled", "model", "sendMetadata",
            "pathAnonymization", "localVision", "apiKey",
        ]
        let actual = Set(AIConfigKey.allCases.map(\.rawValue))
        #expect(actual == expected)
    }

    @Test("Defaults have same key count as AIConfigKey cases")
    func defaultsKeyCountMatchesConfigKey() {
        #expect(AIConfig.defaults.count == AIConfigKey.allCases.count)
    }
}

@Suite("AIConfig Keychain Integration")
struct AIConfigKeychainTests {

    @Test("getAPIKey returns Keychain value when present")
    func testGetAPIKeyFromKeychain() throws {
        let service = "com.nadav.deepfinder.test.\(UUID().uuidString.prefix(8))"
        let store = KeychainStore(service: service)
        try store.save(key: "ai.apiKey", value: "sk-test-from-keychain")
        let key = AIConfig.getAPIKey(config: ["ai.apiKey": "unused"], keychainStore: store)
        #expect(key == "sk-test-from-keychain")
        store.delete(key: "ai.apiKey")
    }

    @Test("getAPIKey falls back to config dict when Keychain empty")
    func testFallbackToConfig() {
        let store = KeychainStore(service: "com.nadav.deepfinder.test.nonexistent")
        let key = AIConfig.getAPIKey(config: ["ai.apiKey": "sk-fallback"], keychainStore: store)
        #expect(key == "sk-fallback")
    }

    @Test("dataPreview returns JSON sample of sent data")
    func testDataPreview() {
        let preview = AIConfig.dataPreview()
        #expect(preview.contains("name"))
        #expect(preview.contains("path"))
        #expect(preview.contains("size"))
        #expect(preview.contains("extension"))
    }
}
