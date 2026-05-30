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
    }

    /// Create a SettingsViewModel with a mock provider on the main actor.
    @MainActor
    private func makeViewModel(provider: MockConfigProvider? = nil) -> SettingsViewModel {
        let mock = provider ?? MockConfigProvider()
        return SettingsViewModel(configProvider: mock)
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
}
