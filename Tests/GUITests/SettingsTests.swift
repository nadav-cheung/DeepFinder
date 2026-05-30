import XCTest
import SwiftUI
@testable import DeepFinder

final class SettingsTests: XCTestCase {

    // MARK: - Helpers

    /// Mock config provider that stores state in memory, no IPC.
    private final class MockConfigProvider: SettingsConfigProvider, @unchecked Sendable {
        var excludedPaths: [String] = ["/System", "/Library"]
        var onAddPath: ((String) -> Void)?
        var onRemovePath: ((String) -> Void)?
        var rebuildTriggered = false

        func getExcludedPaths() async -> [String] {
            excludedPaths
        }

        func addExcludedPath(_ path: String) async {
            excludedPaths.append(path)
            onAddPath?(path)
        }

        func removeExcludedPath(_ path: String) async {
            excludedPaths.removeAll { $0 == path }
            onRemovePath?(path)
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

    @MainActor
    func testSettingsViewRendersTabs() async {
        let vm = makeViewModel()
        let _ = SettingsView(viewModel: vm)

        // Verify the view model tab state works correctly.
        XCTAssertEqual(vm.selectedTab, .general)
        vm.selectedTab = .index
        XCTAssertEqual(vm.selectedTab, .index)
        vm.selectedTab = .ai
        XCTAssertEqual(vm.selectedTab, .ai)
        vm.selectedTab = .about
        XCTAssertEqual(vm.selectedTab, .about)
    }

    // MARK: - 2. Excluded paths list displays correctly

    @MainActor
    func testExcludedPathsListDisplaysCorrectly() async {
        let provider = MockConfigProvider()
        provider.excludedPaths = ["/System", "/Library", "/private/var"]
        let vm = makeViewModel(provider: provider)

        await vm.loadConfig()
        XCTAssertEqual(vm.excludedPaths, ["/System", "/Library", "/private/var"])
    }

    // MARK: - 3. Add path updates config

    @MainActor
    func testAddPathUpdatesConfig() async {
        let provider = MockConfigProvider()
        provider.excludedPaths = ["/System"]
        let vm = makeViewModel(provider: provider)
        await vm.loadConfig()

        let expectation = expectation(description: "addExcludedPath called")
        provider.onAddPath = { path in
            if path == "/tmp/test" {
                expectation.fulfill()
            }
        }

        await vm.addPath("/tmp/test")
        XCTAssertTrue(vm.excludedPaths.contains("/tmp/test"))
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - 4. Remove path updates config

    @MainActor
    func testRemovePathUpdatesConfig() async {
        let provider = MockConfigProvider()
        provider.excludedPaths = ["/System", "/Library"]
        let vm = makeViewModel(provider: provider)
        await vm.loadConfig()

        let expectation = expectation(description: "removeExcludedPath called")
        provider.onRemovePath = { path in
            if path == "/Library" {
                expectation.fulfill()
            }
        }

        await vm.removePath("/Library")
        XCTAssertFalse(vm.excludedPaths.contains("/Library"))
        XCTAssertTrue(vm.excludedPaths.contains("/System"))
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - 5. Index stats display

    @MainActor
    func testIndexStatsDisplay() async {
        let provider = MockConfigProvider()
        let vm = makeViewModel(provider: provider)

        await vm.loadIndexStats()
        XCTAssertNotNil(vm.indexStats)
        XCTAssertEqual(vm.indexStats?.state, "live")
        XCTAssertEqual(vm.indexStats?.filesIndexed, 12345)
    }

    // MARK: - 6. Version displays from VERSION constant

    @MainActor
    func testVersionDisplaysFromConstant() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.version, Product.version)
        XCTAssertFalse(vm.version.isEmpty)
    }

    // MARK: - 7. Rebuild index triggers provider

    @MainActor
    func testRebuildIndexTriggersProvider() async {
        let provider = MockConfigProvider()
        let vm = makeViewModel(provider: provider)

        XCTAssertFalse(provider.rebuildTriggered)
        XCTAssertFalse(vm.isRebuilding)

        await vm.rebuildIndex()

        XCTAssertTrue(provider.rebuildTriggered)
        XCTAssertFalse(vm.isRebuilding)
    }

    // MARK: - 8. Hotkey display defaults and resets

    @MainActor
    func testHotkeyDisplayDefaultsAndResets() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.hotkeyDisplay, "⌃⌘K")

        vm.hotkeyDisplay = "⌥⌘F"
        XCTAssertEqual(vm.hotkeyDisplay, "⌥⌘F")

        vm.resetHotkeyDisplay()
        XCTAssertEqual(vm.hotkeyDisplay, "⌃⌘K")
    }

    // MARK: - 9. AI config loads from provider

    @MainActor
    func testAIConfigLoadsFromProvider() async {
        let aiProvider = MockAIProvider()
        aiProvider.enabled = true
        aiProvider.model = "deepseek"
        aiProvider.apiKey = "sk-test-123"
        aiProvider.sendMetadata = true
        aiProvider.pathAnonymization = false
        aiProvider.localVision = false

        let vm = makeViewModel(aiProvider: aiProvider)
        await vm.loadAIConfig()

        XCTAssertTrue(vm.aiEnabled)
        XCTAssertEqual(vm.aiModel, .deepseek)
        XCTAssertEqual(vm.aiAPIKeyText, "sk-test-123")
        XCTAssertTrue(vm.aiSendMetadata)
        XCTAssertFalse(vm.aiPathAnonymization)
        XCTAssertFalse(vm.aiLocalVision)
    }

    // MARK: - 10. AI config defaults when no provider

    @MainActor
    func testAIConfigDefaultsWhenNoProvider() async {
        let vm = SettingsViewModel(configProvider: MockConfigProvider(), aiProvider: nil, launchProvider: MockLaunchAtLoginProvider())
        await vm.loadAIConfig()

        XCTAssertFalse(vm.aiEnabled)
        XCTAssertEqual(vm.aiModel, .off)
        XCTAssertEqual(vm.aiAPIKeyText, "")
        XCTAssertFalse(vm.aiSendMetadata)
        XCTAssertTrue(vm.aiPathAnonymization)
        XCTAssertTrue(vm.aiLocalVision)
    }

    // MARK: - 11. AI enabled toggle persists

    @MainActor
    func testAIEnabledTogglePersists() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        XCTAssertFalse(aiProvider.enabled)
        await vm.setAIEnabled(true)
        XCTAssertTrue(vm.aiEnabled)
        XCTAssertTrue(aiProvider.enabled)

        await vm.setAIEnabled(false)
        XCTAssertFalse(vm.aiEnabled)
        XCTAssertFalse(aiProvider.enabled)
    }

    // MARK: - 12. AI model selection persists

    @MainActor
    func testAIModelSelectionPersists() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        XCTAssertEqual(vm.aiModel, .off)

        await vm.setAIModel(.qwen)
        XCTAssertEqual(vm.aiModel, .qwen)
        XCTAssertEqual(aiProvider.model, "qwen")

        await vm.setAIModel(.deepseek)
        XCTAssertEqual(vm.aiModel, .deepseek)
        XCTAssertEqual(aiProvider.model, "deepseek")
    }

    // MARK: - 13. AI API key persists

    @MainActor
    func testAIAPIKeyPersists() async throws {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        try await vm.setAIKey("sk-new-key")
        XCTAssertEqual(vm.aiAPIKeyText, "sk-new-key")
        XCTAssertEqual(aiProvider.apiKey, "sk-new-key")
    }

    // MARK: - 14. AI send metadata toggle persists

    @MainActor
    func testAISendMetadataTogglePersists() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        XCTAssertFalse(vm.aiSendMetadata)
        await vm.setAISendMetadata(true)
        XCTAssertTrue(vm.aiSendMetadata)
        XCTAssertTrue(aiProvider.sendMetadata)
    }

    // MARK: - 15. AI path anonymization toggle persists

    @MainActor
    func testAIPathAnonymizationTogglePersists() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        XCTAssertTrue(vm.aiPathAnonymization)
        await vm.setAIPathAnonymization(false)
        XCTAssertFalse(vm.aiPathAnonymization)
        XCTAssertFalse(aiProvider.pathAnonymization)
    }

    // MARK: - 16. AI local vision toggle persists

    @MainActor
    func testAILocalVisionTogglePersists() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        XCTAssertTrue(vm.aiLocalVision)
        await vm.setAILocalVision(false)
        XCTAssertFalse(vm.aiLocalVision)
        XCTAssertFalse(aiProvider.localVision)
    }

    // MARK: - 17. AI data preview loads

    @MainActor
    func testAIDataPreviewLoads() async {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        XCTAssertTrue(vm.aiPreviewData.isEmpty)
        await vm.loadAIPreview()
        XCTAssertFalse(vm.aiPreviewData.isEmpty)
        XCTAssertTrue(vm.aiPreviewData.contains("name"))
        XCTAssertTrue(vm.aiPreviewData.contains("path"))
    }

    // MARK: - 18. AI data preview fallback without provider

    @MainActor
    func testAIDataPreviewFallbackWithoutProvider() async {
        let vm = SettingsViewModel(configProvider: MockConfigProvider(), aiProvider: nil, launchProvider: MockLaunchAtLoginProvider())

        await vm.loadAIPreview()
        XCTAssertFalse(vm.aiPreviewData.isEmpty)
        // Should fall back to AIConfig.dataPreview()
        XCTAssertTrue(vm.aiPreviewData.contains("example.pdf"))
    }

    // MARK: - 19. AIModelOption all cases

    func testAIModelOptionAllCases() {
        let allRaw = Set(AIModelOption.allCases.map(\.rawValue))
        XCTAssertEqual(allRaw, Set(["off", "deepseek", "qwen"]))
    }

    // MARK: - 20. AIModelOption display names

    func testAIModelOptionDisplayNames() {
        XCTAssertEqual(AIModelOption.off.displayName, "Off")
        XCTAssertEqual(AIModelOption.deepseek.displayName, "DeepSeek")
        XCTAssertEqual(AIModelOption.qwen.displayName, "Qwen")
    }

    // MARK: - 21. SettingsTab includes ai

    func testSettingsTabIncludesAI() {
        let allTabs = Set(SettingsTab.allCases)
        XCTAssertTrue(allTabs.contains(.ai))
        XCTAssertEqual(SettingsTab.allCases.count, 4)
    }

    // MARK: - 22. AI config load then mutate round-trips correctly

    @MainActor
    func testAIConfigRoundTrip() async throws {
        let aiProvider = MockAIProvider()
        let vm = makeViewModel(aiProvider: aiProvider)

        // Load defaults
        await vm.loadAIConfig()
        XCTAssertFalse(vm.aiEnabled)
        XCTAssertEqual(vm.aiModel, .off)

        // Change everything
        await vm.setAIEnabled(true)
        await vm.setAIModel(.deepseek)
        try await vm.setAIKey("sk-roundtrip")
        await vm.setAISendMetadata(true)
        await vm.setAIPathAnonymization(false)
        await vm.setAILocalVision(false)

        // Verify in-memory state
        XCTAssertTrue(vm.aiEnabled)
        XCTAssertEqual(vm.aiModel, .deepseek)
        XCTAssertEqual(vm.aiAPIKeyText, "sk-roundtrip")
        XCTAssertTrue(vm.aiSendMetadata)
        XCTAssertFalse(vm.aiPathAnonymization)
        XCTAssertFalse(vm.aiLocalVision)

        // Verify provider state
        XCTAssertTrue(aiProvider.enabled)
        XCTAssertEqual(aiProvider.model, "deepseek")
        XCTAssertEqual(aiProvider.apiKey, "sk-roundtrip")
        XCTAssertTrue(aiProvider.sendMetadata)
        XCTAssertFalse(aiProvider.pathAnonymization)
        XCTAssertFalse(aiProvider.localVision)
    }

    // MARK: - 23. Auto-launch loads from provider

    @MainActor
    func testAutoLaunchLoadsFromProvider() async {
        let launchProvider = MockLaunchAtLoginProvider()
        launchProvider.enabled = true
        let vm = makeViewModel(launchProvider: launchProvider)

        XCTAssertFalse(vm.autoLaunchEnabled)
        await vm.loadAutoLaunchConfig()
        XCTAssertTrue(vm.autoLaunchEnabled)
    }

    // MARK: - 24. Auto-launch toggle enables

    @MainActor
    func testAutoLaunchToggleEnables() async {
        let launchProvider = MockLaunchAtLoginProvider()
        let vm = makeViewModel(launchProvider: launchProvider)

        XCTAssertFalse(vm.autoLaunchEnabled)
        await vm.setAutoLaunch(true)
        XCTAssertTrue(vm.autoLaunchEnabled)
        XCTAssertTrue(launchProvider.enabled)
    }

    // MARK: - 25. Auto-launch toggle disables

    @MainActor
    func testAutoLaunchToggleDisables() async {
        let launchProvider = MockLaunchAtLoginProvider()
        launchProvider.enabled = true
        let vm = makeViewModel(launchProvider: launchProvider)
        await vm.loadAutoLaunchConfig()

        XCTAssertTrue(vm.autoLaunchEnabled)
        await vm.setAutoLaunch(false)
        XCTAssertFalse(vm.autoLaunchEnabled)
        XCTAssertFalse(launchProvider.enabled)
    }

    // MARK: - 26. Auto-launch failure sets error

    @MainActor
    func testAutoLaunchFailureSetsError() async {
        let launchProvider = MockLaunchAtLoginProvider()
        launchProvider.shouldFail = true
        let vm = makeViewModel(launchProvider: launchProvider)

        XCTAssertNil(vm.autoLaunchError)
        await vm.setAutoLaunch(true)
        XCTAssertFalse(vm.autoLaunchEnabled)
        XCTAssertNotNil(vm.autoLaunchError)
        XCTAssertTrue(vm.autoLaunchError!.contains("Failed"))
    }

    // MARK: - 27. Auto-launch error clears on retry

    @MainActor
    func testAutoLaunchErrorClearsOnRetry() async {
        let launchProvider = MockLaunchAtLoginProvider()
        launchProvider.shouldFail = true
        let vm = makeViewModel(launchProvider: launchProvider)

        await vm.setAutoLaunch(true)
        XCTAssertNotNil(vm.autoLaunchError)

        launchProvider.shouldFail = false
        await vm.setAutoLaunch(true)
        XCTAssertTrue(vm.autoLaunchEnabled)
        XCTAssertNil(vm.autoLaunchError)
    }
}
