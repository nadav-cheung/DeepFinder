import SwiftUI

// MARK: - SettingsConfigProvider

/// Protocol abstracting config access for the Settings view.
///
/// In production, this is backed by IPC calls to the daemon's ConfigStore.
/// In tests, this is replaced by a mock that stores state in memory.
protocol SettingsConfigProvider: Sendable {
    func getExcludedPaths() async -> [String]
    func addExcludedPath(_ path: String) async
    func removeExcludedPath(_ path: String) async
    func getIndexStats() async -> SettingsIndexStats
}

// MARK: - SettingsIndexStats

/// Index statistics displayed in the Settings Index tab.
struct SettingsIndexStats: Sendable, Equatable {
    let state: String
    let filesIndexed: Int
    let lastScanDate: Date?
}

// MARK: - SettingsTab

/// Tabs in the Settings window.
enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case index
    case about
}

// MARK: - SettingsViewModel

/// View model driving the Settings view.
///
/// Bridges the SwiftUI view layer with the async config provider (IPC in production, mock in tests).
/// All mutations go through the config provider so changes are persisted to the daemon.
@MainActor
@Observable
final class SettingsViewModel {

    // MARK: - State

    /// Currently selected tab.
    var selectedTab: SettingsTab = .general

    /// List of paths excluded from indexing.
    var excludedPaths: [String] = []

    /// Index statistics from the daemon.
    var indexStats: SettingsIndexStats?

    /// Text field input for adding a new excluded path.
    var newPathText: String = ""

    /// The app version string.
    let version: String

    // MARK: - Dependencies

    private let configProvider: any SettingsConfigProvider

    // MARK: - Init

    init(configProvider: any SettingsConfigProvider) {
        self.configProvider = configProvider
        self.version = Product.version
    }

    // MARK: - Config Loading

    /// Load excluded paths and index stats from the config provider.
    func loadConfig() async {
        excludedPaths = await configProvider.getExcludedPaths()
    }

    /// Load index statistics from the daemon.
    func loadIndexStats() async {
        indexStats = await configProvider.getIndexStats()
    }

    // MARK: - Path Mutations

    /// Add a path to the exclusion list and persist via the provider.
    func addPath(_ path: String) async {
        await configProvider.addExcludedPath(path)
        excludedPaths = await configProvider.getExcludedPaths()
    }

    /// Remove a path from the exclusion list and persist via the provider.
    func removePath(_ path: String) async {
        await configProvider.removeExcludedPath(path)
        excludedPaths = await configProvider.getExcludedPaths()
    }
}

// MARK: - SettingsView

/// Settings window content with three tabs: General, Index, About.
struct SettingsView: View {

    let viewModel: SettingsViewModel

    var body: some View {
        TabView(selection: Binding(
            get: { viewModel.selectedTab },
            set: { viewModel.selectedTab = $0 }
        )) {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            indexTab
                .tabItem {
                    Label("Index", systemImage: "doc.text.magnifyingglass")
                }
                .tag(SettingsTab.index)

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 480, minHeight: 360)
        .task {
            await viewModel.loadConfig()
            await viewModel.loadIndexStats()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        @Bindable var vm = viewModel
        return Form {
            Section("Excluded Paths") {
                List {
                    ForEach(viewModel.excludedPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder.badge.minus")
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                Task { await viewModel.removePath(path) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(path)")
                        }
                    }
                }

                HStack {
                    TextField("Path to exclude", text: $vm.newPathText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Add") {
                        let path = viewModel.newPathText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !path.isEmpty else { return }
                        Task { await viewModel.addPath(path) }
                        viewModel.newPathText = ""
                    }
                    .disabled(viewModel.newPathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding()
    }

    // MARK: - Index Tab

    private var indexTab: some View {
        Form {
            Section("Index Status") {
                if let stats = viewModel.indexStats {
                    LabeledContent("State") {
                        Text(stats.state.capitalized)
                            .foregroundStyle(stats.state == "live" ? .green : .orange)
                    }
                    LabeledContent("Files Indexed") {
                        Text(stats.filesIndexed.formatted())
                    }
                    if let date = stats.lastScanDate {
                        LabeledContent("Last Scan") {
                            Text(date, format: .dateTime)
                        }
                    }
                } else {
                    Text("Loading...")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Maintenance") {
                Button("Rebuild Index") {
                    // Will be wired to IPC in v2.0 integration
                }
            }
        }
        .padding()
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(Product.name)
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(viewModel.version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Fast file search for macOS")
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
