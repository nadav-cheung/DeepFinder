import Testing
import SwiftUI
@testable import DeepFinder

struct SettingsTests {

    // MARK: - Helpers

    /// Mock config provider that stores state in memory, no IPC.
    private final class MockConfigProvider: SettingsConfigProvider, @unchecked Sendable {
        var excludedPaths: [String] = ["/System", "/Library"]
        var rebuildTriggered = false

        func getExcludedPaths() async -> [String] {
            excludedPaths
        }

        func addExcludedPath(_ path: String) async {
            excludedPaths.append(path)
        }

        func removeExcludedPath(_ path: String) async {
            excludedPaths.removeAll { $0 == path }
        }

        func getIndexStats() async -> SettingsIndexStats {
            SettingsIndexStats(
                state: "live",
                filesIndexed: 12345,
                lastScanDate: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        func triggerRebuildIndex() async {
            rebuildTriggered = true
        }
    }

    /// Mock AI provider that stores state in memory.
    private final class MockAIProvider: SettingsAIProvider, @unchecked Sendable {
        var enabled: Bool = false
        var model: String = "off"
        var apiKey: String = ""
        var sendMetadata: Bool = false
        var pathAnonymization: Bool = true
        var localVision: Bool = true

        func isEnabled() async -> Bool { enabled }
        func setEnabled(_ enabled: Bool) async { self.enabled = enabled }
        func modelName() async -> String { model }
        func setModel(_ model: String) async { self.model = model }
        func getAPIKey() async -> String { apiKey }
        func setAPIKey(_ key: String) async throws { self.apiKey = key }
        func sendMetadata() async -> Bool { sendMetadata }
        func setSendMetadata(_ enabled: Bool) async { self.sendMetadata = enabled }
        func pathAnonymization() async -> Bool { pathAnonymization }
        func setPathAnonymization(_ enabled: Bool) async { self.pathAnonymization = enabled }
        func localVision() async -> Bool { localVision }
        func setLocalVision(_ enabled: Bool) async { self.localVision = enabled }
        func dataPreview() async -> String { AIConfig.dataPreview() }
    }

    /// Mock launch-at-login provider that stores state in memory.
    private final class MockLaunchAtLoginProvider: LaunchAtLoginProvider, @unchecked Sendable {
        var enabled: Bool = false
        var shouldFail: Bool = false

        func isEnabled() async -> Bool { enabled }

        func setEnabled(_ enabled: Bool) async -> Bool {
            guard !shouldFail else { return false }
            self.enabled = enabled
            return true
        }
    }

    /// Create a SettingsViewModel with mock providers on the main actor.
    @MainActor
    private func makeViewModel(
        provider: MockConfigProvider? = nil,
        aiProvider: MockAIProvider? = nil,
        launchProvider: (any LaunchAtLoginProvider)? = nil
    ) -> SettingsViewModel {
        let mock = provider ?? MockConfigProvider()
        let ai = aiProvider ?? MockAIProvider()
        let launch = launchProvider ?? MockLaunchAtLoginProvider()
        return SettingsViewModel(configProvider: mock, aiProvider: ai, launchProvider: launch)
    }

    // MARK: - 1. Settings view renders tabs

    @Test @MainActor func settingsViewRendersTabs() async {
        let vm = makeViewModel()

        // Verify the view model tab state works correctly.
        #expect(vm.selectedTab == .general)
        vm.selectedTab = .index
        #expect(vm.selectedTab == .index)
        vm.selectedTab = .ai
        #expect(vm.selectedTab == .ai)
        vm.selectedTab = .about
        #expect(vm.selectedTab == .about)
    }

    // MARK: - 2. Excluded paths list displays correctly

    @Test @MainActor func excludedPathsListDisplaysCorrectly() async {
        let provider = MockConfigProvider()
        provider.excludedPaths = ["/System", "/Library", "/private/var"]
        let vm = makeViewModel(provider: provider)

        await vm.loadConfig()
        #expect(vm.excludedPaths == ["/System", "/Library", "/private/var"])
    }

    // MARK: - 3. Add path updates config

    @Test @MainActor func addPathUpdatesConfig() async {
        let provider = MockConfigProvider()
        provider.excludedPaths = ["/System"]
        let vm = makeViewModel(provider: provider)
        await vm.loadConfig()

        await vm.addPath("/tmp/test")
        #expect(vm.excludedPaths.contains("/tmp/test"))
        // Verify provider was also updated
        #expect(provider.excludedPaths.contains("/tmp/test"))
    }

    // MARK: - 4. Remove path updates config

    @Test @MainActor func removePathUpdatesConfig() async {
        let provider = MockConfigProvider()
        provider.excludedPaths = ["/System", "/Library"]
        let vm = makeViewModel(provider: provider)
        await vm.loadConfig()

        await vm.removePath("/Library")
        #expect(!vm.excludedPaths.contains("/Library"))
        #expect(vm.excludedPaths.contains("/System"))
        // Verify provider was also updated
        #expect(!provider.excludedPaths.contains("/Library"))
    }

    // MARK: - 5. Index stats display

    @Test @MainActor func indexStatsDisplay() async {
        let provider = MockConfigProvider()
        let vm = makeViewModel(provider: provider)

        await vm.loadIndexStats()
        #expect(vm.indexStats != nil)
        #expect(vm.indexStats?.state == "live")
        #expect(vm.indexStats?.filesIndexed == 12345)
    }

    // MARK: - 6. Version displays from VERSION constant

    @Test @MainActor func versionDisplaysFromConstant() {
        let vm = makeViewModel()
        #expect(vm.version == Product.version)
        #expect(!vm.version.isEmpty)
    }

    // MARK: - 7. Rebuild index triggers provider

    @Test @MainActor func rebuildIndexTriggersProvider() async {
        let provider = MockConfigProvider()
        let vm = makeViewModel(provider: provider)

        #expect(!provider.rebuildTriggered)
        #expect(!vm.isRebuilding)

        await vm.rebuildIndex()

        #expect(provider.rebuildTriggered)
        #expect(!vm.isRebuilding)
    }

    // MARK: - 8. Hotkey display defaults and resets

    @Test @MainActor func hotkeyDisplayDefaultsAndResets() {
        let vm = makeViewModel()
        #expect(vm.hotkeyDisplay == "\u{2303}\u{2318}K")

        vm.hotkeyDisplay = "\u{2325}\u{2318}F"
        #expect(vm.hotkeyDisplay == "\u{2325}\u{2318}F")

        vm.resetHotkeyDisplay()
        #expect(vm.hotkeyDisplay == "\u{2303}\u{2318}K")
    }

    // MARK: - 9. AI config loads from provider

    @Test @MainActor func aiConfigLoadsFromProvider() async {
        let aiProvider = MockAIProvider()
        aiProvider.enabled = true
        aiProvider.model = "deepseek"
        aiProvider.apiKey = "sk-test-123"
        aiProvider.sendMetadata = true
        aiProvider.pathAnonymization = false
        aiProvider.localVision = false

        let vm = makeViewModel(aiProvider: aiProvider)
        await vm.loadAIConfig()

        #expect(vm.aiEnabled)
        #expect(vm.aiModel == .deepseek)
        #expect(vm.aiAPIKeyText == "sk-test-123")
        #expect(vm.aiSendMetadata)
        #expect(!vm.aiPathAnonymization)
        #expect(!vm.aiLocalVision)
    }

    // MARK: - 10. AI config defaults when no provider

    @Test @MainActor func aiConfigDefaultsWhenNoProvider() async {
        let vm = SettingsViewModel(configProvider: MockConfigProvider(), aiProvider: nil, launchProvider: MockLaunchAtLoginProvider())
        await vm.loadAIConfig()

        #expect(!vm.aiEnabled)
        #expect(vm.aiModel == .off)
        #expect(vm.aiAPIKeyText == "")
        #expect(!vm.aiSendMetadata)
        #expect(vm.aiPathAnonymization)
        #expect(vm.aiLocalVision)
    }

    // MARK: - 11. AI enabled toggle persists

    @Test @MainActor func aiEnabledTogglePersists() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        #expect(!aiProvider.enabled)
        await vm.setAIEnabled(true)
        #expect(vm.aiEnabled)
        #expect(aiProvider.enabled)

        await vm.setAIEnabled(false)
        #expect(!vm.aiEnabled)
        #expect(!aiProvider.enabled)
    }

    // MARK: - 12. AI model selection persists

    @Test @MainActor func aiModelSelectionPersists() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        #expect(vm.aiModel == .off)

        await vm.setAIModel(.qwen)
        #expect(vm.aiModel == .qwen)
        #expect(aiProvider.model == "qwen")

        await vm.setAIModel(.deepseek)
        #expect(vm.aiModel == .deepseek)
        #expect(aiProvider.model == "deepseek")
    }

    // MARK: - 13. AI API key persists

    @Test @MainActor func aiAPIKeyPersists() async throws {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        await vm.setAIKey("sk-new-key")
        #expect(vm.aiAPIKeyText == "sk-new-key")
        #expect(aiProvider.apiKey == "sk-new-key")
    }

    // MARK: - 14. AI send metadata toggle persists

    @Test @MainActor func aiSendMetadataTogglePersists() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        #expect(!vm.aiSendMetadata)
        await vm.setAISendMetadata(true)
        #expect(vm.aiSendMetadata)
        #expect(aiProvider.sendMetadata)
    }

    // MARK: - 15. AI path anonymization toggle persists

    @Test @MainActor func aiPathAnonymizationTogglePersists() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        #expect(vm.aiPathAnonymization)
        await vm.setAIPathAnonymization(false)
        #expect(!vm.aiPathAnonymization)
        #expect(!aiProvider.pathAnonymization)
    }

    // MARK: - 16. AI local vision toggle persists

    @Test @MainActor func aiLocalVisionTogglePersists() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        #expect(vm.aiLocalVision)
        await vm.setAILocalVision(false)
        #expect(!vm.aiLocalVision)
        #expect(!aiProvider.localVision)
    }

    // MARK: - 17. AI data preview loads

    @Test @MainActor func aiDataPreviewLoads() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        #expect(vm.aiPreviewData.isEmpty)
        await vm.loadAIPreview()
        #expect(!vm.aiPreviewData.isEmpty)
        #expect(vm.aiPreviewData.contains("name"))
        #expect(vm.aiPreviewData.contains("path"))
    }

    // MARK: - 18. AI data preview fallback without provider

    @Test @MainActor func aiDataPreviewFallbackWithoutProvider() async {
        let vm = SettingsViewModel(configProvider: MockConfigProvider(), aiProvider: nil, launchProvider: MockLaunchAtLoginProvider())

        await vm.loadAIPreview()
        #expect(!vm.aiPreviewData.isEmpty)
        // Should fall back to AIConfig.dataPreview()
        #expect(vm.aiPreviewData.contains("example.pdf"))
    }

    // MARK: - 19. AIModelOption all cases

    @Test func aiModelOptionAllCases() {
        let allRaw = Set(AIModelOption.allCases.map(\.rawValue))
        #expect(allRaw == Set(["off", "deepseek", "qwen"]))
    }

    // MARK: - 20. AIModelOption display names

    @Test func aiModelOptionDisplayNames() {
        #expect(AIModelOption.off.displayName == "Off")
        #expect(AIModelOption.deepseek.displayName == "DeepSeek")
        #expect(AIModelOption.qwen.displayName == "Qwen")
    }

    // MARK: - 21. SettingsTab includes ai

    @Test func settingsTabIncludesAI() {
        let allTabs = Set(SettingsTab.allCases)
        #expect(allTabs.contains(.ai))
        #expect(SettingsTab.allCases.count == 4)
    }

    // MARK: - 22. AI config load then mutate round-trips correctly

    @Test @MainActor func aiConfigRoundTrip() async throws {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        // Load defaults
        await vm.loadAIConfig()
        #expect(!vm.aiEnabled)
        #expect(vm.aiModel == .off)

        // Change everything
        await vm.setAIEnabled(true)
        await vm.setAIModel(.deepseek)
        await vm.setAIKey("sk-roundtrip")
        await vm.setAISendMetadata(true)
        await vm.setAIPathAnonymization(false)
        await vm.setAILocalVision(false)

        // Verify in-memory state
        #expect(vm.aiEnabled)
        #expect(vm.aiModel == .deepseek)
        #expect(vm.aiAPIKeyText == "sk-roundtrip")
        #expect(vm.aiSendMetadata)
        #expect(!vm.aiPathAnonymization)
        #expect(!vm.aiLocalVision)

        // Verify provider state
        #expect(aiProvider.enabled)
        #expect(aiProvider.model == "deepseek")
        #expect(aiProvider.apiKey == "sk-roundtrip")
        #expect(aiProvider.sendMetadata)
        #expect(!aiProvider.pathAnonymization)
        #expect(!aiProvider.localVision)
    }

    // MARK: - 23. Auto-launch loads from provider

    @Test @MainActor func autoLaunchLoadsFromProvider() async {
        let launchProvider = MockLaunchAtLoginProvider()
        launchProvider.enabled = true
        let vm = makeViewModel(launchProvider: launchProvider)

        #expect(!vm.autoLaunchEnabled)
        await vm.loadAutoLaunchConfig()
        #expect(vm.autoLaunchEnabled)
    }

    // MARK: - 24. Auto-launch toggle enables

    @Test @MainActor func autoLaunchToggleEnables() async {
        let launchProvider = MockLaunchAtLoginProvider()
        let vm = makeViewModel(launchProvider: launchProvider)

        #expect(!vm.autoLaunchEnabled)
        await vm.setAutoLaunch(true)
        #expect(vm.autoLaunchEnabled)
        #expect(launchProvider.enabled)
    }

    // MARK: - 25. Auto-launch toggle disables

    @Test @MainActor func autoLaunchToggleDisables() async {
        let launchProvider = MockLaunchAtLoginProvider()
        launchProvider.enabled = true
        let vm = makeViewModel(launchProvider: launchProvider)
        await vm.loadAutoLaunchConfig()

        #expect(vm.autoLaunchEnabled)
        await vm.setAutoLaunch(false)
        #expect(!vm.autoLaunchEnabled)
        #expect(!launchProvider.enabled)
    }

    // MARK: - 26. Auto-launch failure sets error

    @Test @MainActor func autoLaunchFailureSetsError() async {
        let launchProvider = MockLaunchAtLoginProvider()
        launchProvider.shouldFail = true
        let vm = makeViewModel(launchProvider: launchProvider)

        #expect(vm.autoLaunchError == nil)
        await vm.setAutoLaunch(true)
        #expect(!vm.autoLaunchEnabled)
        #expect(vm.autoLaunchError != nil)
        #expect(vm.autoLaunchError!.contains("Failed"))
    }

    // MARK: - 27. Auto-launch error clears on retry

    @Test @MainActor func autoLaunchErrorClearsOnRetry() async {
        let launchProvider = MockLaunchAtLoginProvider()
        launchProvider.shouldFail = true
        let vm = makeViewModel(launchProvider: launchProvider)

        await vm.setAutoLaunch(true)
        #expect(vm.autoLaunchError != nil)

        launchProvider.shouldFail = false
        await vm.setAutoLaunch(true)
        #expect(vm.autoLaunchEnabled)
        #expect(vm.autoLaunchError == nil)
    }
}
