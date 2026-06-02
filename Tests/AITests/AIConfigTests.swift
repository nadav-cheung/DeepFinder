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
            "cloudFallback", "embeddingModel", "cacheTTL",
            "customEndpoint", "customModelName", "customAPIKey",
        ]
        let actual = Set(AIConfigKey.allCases.map(\.rawValue))
        #expect(actual == expected)
    }

    @Test("Defaults have same key count as AIConfigKey cases")
    func defaultsKeyCountMatchesConfigKey() {
        #expect(AIConfig.defaults.count == AIConfigKey.allCases.count)
    }
}

@Suite("AIConfig Secrets Integration")
struct AIConfigSecretsTests {

    /// Create a test-scoped SecretsStore backed by a temp file.
    private func makeStore() -> (SecretsStore, cleanup: () -> Void) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepfinder-test-aiconfig-\(UUID().uuidString)")
        let filePath = tmpDir.appendingPathComponent("secrets.json").path
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = SecretsStore(filePath: filePath)
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: tmpDir) }
        return (store, cleanup)
    }

    @Test("getAPIKey returns secrets file value when present")
    func testGetAPIKeyFromSecrets() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try store.save(key: "ai.apiKey", value: "sk-test-from-secrets")
        let key = AIConfig.getAPIKey(config: ["ai.apiKey": "unused"], secretsStore: store)
        #expect(key == "sk-test-from-secrets")
    }

    @Test("getAPIKey falls back to config dict when secrets file empty")
    func testFallbackToConfig() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        let key = AIConfig.getAPIKey(config: ["ai.apiKey": "sk-fallback"], secretsStore: store)
        #expect(key == "sk-fallback")
    }

    @Test("saveAPIKey writes to secrets file")
    func testSaveAPIKey() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try AIConfig.saveAPIKey("sk-new-key", secretsStore: store)
        #expect(store.load(key: "ai.apiKey") == "sk-new-key")
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
