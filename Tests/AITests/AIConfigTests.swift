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
