import SwiftUI
import ServiceManagement

// MARK: - LaunchAtLoginProvider

/// Protocol abstracting launch-at-login for testability.
///
/// In production, ``SystemLaunchAtLoginProvider`` wraps `SMAppService`.
/// In tests, a mock stores the enabled state in memory.
protocol LaunchAtLoginProvider: Sendable {
    func isEnabled() async -> Bool
    func setEnabled(_ enabled: Bool) async -> Bool
}

/// Production implementation using `SMAppService` (macOS 13+).
struct SystemLaunchAtLoginProvider: LaunchAtLoginProvider {
    func isEnabled() async -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) async -> Bool {
        do {
            if enabled {
                try await SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}

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
    func triggerRebuildIndex() async
}

// MARK: - SettingsAIProvider

/// Protocol abstracting AI config access for the Settings AI tab.
///
/// Decouples the view model from KeychainStore and ConfigStore so AI settings
/// can be tested without real Keychain or IPC. In production, the implementation
/// reads/writes through IPC configSet/configGet and KeychainStore for API keys.
protocol SettingsAIProvider: Sendable {
    /// Whether AI assist is enabled.
    func isEnabled() async -> Bool
    /// Set AI assist enabled state.
    func setEnabled(_ enabled: Bool) async
    /// The selected AI model name ("off", "deepseek", "qwen").
    func modelName() async -> String
    /// Set the selected AI model.
    func setModel(_ model: String) async
    /// Retrieve the stored API key (from Keychain).
    func getAPIKey() async -> String
    /// Store the API key (to Keychain).
    func setAPIKey(_ key: String) async throws
    /// Whether metadata is sent to cloud providers.
    func sendMetadata() async -> Bool
    /// Set whether metadata is sent to cloud providers.
    func setSendMetadata(_ enabled: Bool) async
    /// Whether path anonymization is active.
    func pathAnonymization() async -> Bool
    /// Set path anonymization.
    func setPathAnonymization(_ enabled: Bool) async
    /// Whether local vision analysis is enabled.
    func localVision() async -> Bool
    /// Set local vision analysis.
    func setLocalVision(_ enabled: Bool) async
    /// Generate a JSON preview of data sent to AI providers.
    func dataPreview() async -> String
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
    case ai
    case about
}

// MARK: - AIModelOption

/// Options for the AI model picker in Settings.
enum AIModelOption: String, CaseIterable, Sendable {
    case off
    case deepseek
    case qwen

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .deepseek: return "DeepSeek"
        case .qwen: return "Qwen"
        }
    }
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

    // MARK: - AI State

    /// Whether AI assist is enabled.
    var aiEnabled: Bool = false

    /// Selected AI model ("off", "deepseek", "qwen").
    var aiModel: AIModelOption = .off

    /// The API key text (masked in UI, stored in Keychain).
    var aiAPIKeyText: String = ""

    /// Whether metadata is sent to cloud AI providers.
    var aiSendMetadata: Bool = false

    /// Whether path anonymization is active.
    var aiPathAnonymization: Bool = true

    /// Whether local vision analysis is enabled.
    var aiLocalVision: Bool = true

    /// Preview data output from AIConfig.dataPreview().
    var aiPreviewData: String = ""

    /// Whether the preview sheet is visible.
    var aiPreviewVisible: Bool = false

    /// Whether a rebuild index operation is in progress.
    var isRebuilding: Bool = false

    /// The current global hotkey display string.
    var hotkeyDisplay: String = "⌃⌘K"

    // MARK: - Auto-Launch State

    /// Whether auto-launch at login is enabled.
    var autoLaunchEnabled: Bool = false

    /// Alert message shown when auto-launch registration fails.
    var autoLaunchError: String?

    // MARK: - Dependencies

    private let configProvider: any SettingsConfigProvider
    private let aiProvider: (any SettingsAIProvider)?
    private let launchProvider: any LaunchAtLoginProvider

    // MARK: - Init

    init(
        configProvider: any SettingsConfigProvider,
        aiProvider: (any SettingsAIProvider)? = nil,
        launchProvider: any LaunchAtLoginProvider = SystemLaunchAtLoginProvider()
    ) {
        self.configProvider = configProvider
        self.aiProvider = aiProvider
        self.launchProvider = launchProvider
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

    /// Load AI configuration from the AI provider.
    func loadAIConfig() async {
        guard let aiProvider else { return }
        aiEnabled = await aiProvider.isEnabled()
        let model = await aiProvider.modelName()
        aiModel = AIModelOption(rawValue: model) ?? .off
        aiAPIKeyText = await aiProvider.getAPIKey()
        aiSendMetadata = await aiProvider.sendMetadata()
        aiPathAnonymization = await aiProvider.pathAnonymization()
        aiLocalVision = await aiProvider.localVision()
    }

    /// Load auto-launch state from the launch provider.
    func loadAutoLaunchConfig() async {
        autoLaunchEnabled = await launchProvider.isEnabled()
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

    // MARK: - Index Rebuild

    /// Trigger an index rebuild via the config provider.
    func rebuildIndex() async {
        isRebuilding = true
        await configProvider.triggerRebuildIndex()
        isRebuilding = false
        await loadIndexStats()
    }

    // MARK: - AI Mutations

    /// Persist AI enabled state.
    func setAIEnabled(_ enabled: Bool) async {
        aiEnabled = enabled
        await aiProvider?.setEnabled(enabled)
    }

    /// Persist AI model selection.
    func setAIModel(_ model: AIModelOption) async {
        aiModel = model
        await aiProvider?.setModel(model.rawValue)
    }

    /// Persist API key to Keychain.
    func setAIKey(_ key: String) async throws {
        aiAPIKeyText = key
        try await aiProvider?.setAPIKey(key)
    }

    /// Persist send metadata toggle.
    func setAISendMetadata(_ enabled: Bool) async {
        aiSendMetadata = enabled
        await aiProvider?.setSendMetadata(enabled)
    }

    /// Persist path anonymization toggle.
    func setAIPathAnonymization(_ enabled: Bool) async {
        aiPathAnonymization = enabled
        await aiProvider?.setPathAnonymization(enabled)
    }

    /// Persist local vision toggle.
    func setAILocalVision(_ enabled: Bool) async {
        aiLocalVision = enabled
        await aiProvider?.setLocalVision(enabled)
    }

    /// Load the data preview from the AI provider.
    func loadAIPreview() async {
        aiPreviewData = await aiProvider?.dataPreview() ?? AIConfig.dataPreview()
    }

    // MARK: - Hotkey

    /// Reset the global hotkey display to the default.
    func resetHotkeyDisplay() {
        hotkeyDisplay = "⌃⌘K"
    }

    // MARK: - Auto-Launch

    /// Toggle auto-launch at login. Returns false and sets `autoLaunchError` on failure.
    func setAutoLaunch(_ enabled: Bool) async {
        autoLaunchError = nil
        let success = await launchProvider.setEnabled(enabled)
        if success {
            autoLaunchEnabled = enabled
        } else {
            autoLaunchError = "Failed to \(enabled ? "enable" : "disable") login item. Check System Settings > Login Items."
        }
    }
}

// MARK: - SettingsView

/// Settings window content with four tabs: General, Index, AI, About.
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

            aiTab
                .tabItem {
                    Label("AI", systemImage: "brain")
                }
                .tag(SettingsTab.ai)

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
            await viewModel.loadAIConfig()
            await viewModel.loadAutoLaunchConfig()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        @Bindable var vm = viewModel
        return Form {
            Section("Hotkey") {
                HStack {
                    Text("Global Hotkey")
                        .font(.body)
                    Spacer()
                    Text(viewModel.hotkeyDisplay)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                    Button("Reset to Default") {
                        viewModel.resetHotkeyDisplay()
                    }
                }
            }

            Section("Auto-Launch") {
                HStack {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { viewModel.autoLaunchEnabled },
                        set: { newValue in Task { await viewModel.setAutoLaunch(newValue) } }
                    ))
                    Spacer()
                    Text(viewModel.autoLaunchEnabled ? "Enabled" : "Disabled")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = viewModel.autoLaunchError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

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
                    Task { await viewModel.rebuildIndex() }
                }
                .disabled(viewModel.isRebuilding)

                if viewModel.isRebuilding {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Rebuilding index...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - AI Tab

    private var aiTab: some View {
        @Bindable var vm = viewModel
        return Form {
            Section("AI Assist") {
                Toggle("Enable AI Assist", isOn: Binding(
                    get: { viewModel.aiEnabled },
                    set: { newValue in Task { await viewModel.setAIEnabled(newValue) } }
                ))

                Picker("Model", selection: Binding(
                    get: { viewModel.aiModel },
                    set: { newValue in Task { await viewModel.setAIModel(newValue) } }
                )) {
                    ForEach(AIModelOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .disabled(!viewModel.aiEnabled)
            }

            Section("API Key") {
                SecureField("API Key", text: Binding(
                    get: { viewModel.aiAPIKeyText },
                    set: { newValue in
                        viewModel.aiAPIKeyText = newValue
                        Task { try? await viewModel.setAIKey(newValue) }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(!viewModel.aiEnabled)
            }

            Section("Privacy") {
                Toggle("Send Metadata to Cloud", isOn: Binding(
                    get: { viewModel.aiSendMetadata },
                    set: { newValue in Task { await viewModel.setAISendMetadata(newValue) } }
                ))
                .disabled(!viewModel.aiEnabled)

                Toggle("Path Anonymization", isOn: Binding(
                    get: { viewModel.aiPathAnonymization },
                    set: { newValue in Task { await viewModel.setAIPathAnonymization(newValue) } }
                ))
            }

            Section("Local Features") {
                Toggle("Local Vision Analysis", isOn: Binding(
                    get: { viewModel.aiLocalVision },
                    set: { newValue in Task { await viewModel.setAILocalVision(newValue) } }
                ))
            }

            Section("Diagnostics") {
                Button("Preview Data") {
                    Task {
                        await viewModel.loadAIPreview()
                        viewModel.aiPreviewVisible = true
                    }
                }
                .disabled(!viewModel.aiEnabled)
            }
        }
        .padding()
        .sheet(isPresented: Binding(
            get: { viewModel.aiPreviewVisible },
            set: { viewModel.aiPreviewVisible = $0 }
        )) {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI Data Preview")
                    .font(.headline)

                ScrollView {
                    Text(viewModel.aiPreviewData)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)

                HStack {
                    Spacer()
                    Button("Close") { viewModel.aiPreviewVisible = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding()
            .frame(width: 420)
        }
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
