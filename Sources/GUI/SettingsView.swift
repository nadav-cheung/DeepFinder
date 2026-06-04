import SwiftUI

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
        .frame(minWidth: 520, idealWidth: 560, minHeight: 400, idealHeight: 480)
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
        return ScrollView {
            VStack(spacing: 16) {
                glassSection("Hotkey") {
                    HStack {
                        Text("Global Hotkey")
                            .font(.body)
                        Spacer()
                        Text(viewModel.hotkeyDisplay)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: .rect(cornerRadius: 6))
                        Button("Reset to Default") {
                            viewModel.resetHotkeyDisplay()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                glassSection("Auto-Launch") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("Launch at Login", isOn: Binding(
                                get: { viewModel.autoLaunchEnabled },
                                set: { newValue in Task { await viewModel.setAutoLaunch(newValue) } }
                            ))
                            Spacer()
                            statusBadge(
                                text: viewModel.autoLaunchEnabled ? "Enabled" : "Disabled",
                                color: viewModel.autoLaunchEnabled ? .green : .secondary
                            )
                        }
                        if let error = viewModel.autoLaunchError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .padding(.top, 2)
                        }
                    }
                }

                glassSection("Excluded Paths") {
                    VStack(alignment: .leading, spacing: 10) {
                        if viewModel.excludedPaths.isEmpty {
                            Text("No excluded paths")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(viewModel.excludedPaths, id: \.self) { path in
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.badge.minus")
                                        .foregroundStyle(.secondary)
                                        .font(.callout)
                                    Text(path)
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        Task { await viewModel.removePath(path) }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove \(path)")
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        Divider()
                            .padding(.vertical, 2)

                        HStack(spacing: 10) {
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
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Index Tab

    private var indexTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                glassSection("Index Status") {
                    if let stats = viewModel.indexStats {
                        VStack(spacing: 10) {
                            statusRow(
                                label: "State",
                                value: stats.state.capitalized,
                                color: stats.state == "live" ? .green : .orange
                            )
                            Divider()
                            statusRow(
                                label: "Files Indexed",
                                value: stats.filesIndexed.formatted()
                            )
                            if let date = stats.lastScanDate {
                                Divider()
                                statusRow(
                                    label: "Last Scan",
                                    value: date.formatted(.dateTime)
                                )
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading...")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }

                glassSection("Maintenance") {
                    VStack(spacing: 12) {
                        HStack {
                            Button("Rebuild Index") {
                                Task { await viewModel.rebuildIndex() }
                            }
                            .disabled(viewModel.isRebuilding)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            Spacer()
                        }

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
            }
            .padding(20)
        }
    }

    // MARK: - AI Tab

    private var aiTab: some View {
        @Bindable var vm = viewModel
        return ScrollView {
            VStack(spacing: 16) {
                glassSection("AI Assist") {
                    VStack(spacing: 12) {
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
                }

                glassSection("API Key") {
                    SecureField("API Key", text: Binding(
                        get: { viewModel.aiAPIKeyText },
                        set: { newValue in
                            viewModel.aiAPIKeyText = newValue
                            Task { await viewModel.setAIKey(newValue) }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!viewModel.aiEnabled)
                }

                glassSection("Privacy") {
                    VStack(spacing: 12) {
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
                }

                glassSection("Local Features") {
                    Toggle("Local Vision Analysis", isOn: Binding(
                        get: { viewModel.aiLocalVision },
                        set: { newValue in Task { await viewModel.setAILocalVision(newValue) } }
                    ))
                }

                glassSection("Diagnostics") {
                    Button("Preview Data") {
                        Task {
                            await viewModel.loadAIPreview()
                            viewModel.aiPreviewVisible = true
                        }
                    }
                    .disabled(!viewModel.aiEnabled)
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.aiPreviewVisible },
            set: { viewModel.aiPreviewVisible = $0 }
        )) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("AI Data Preview")
                        .font(.headline)
                    Spacer()
                    Button {
                        viewModel.aiPreviewVisible = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                ScrollView {
                    Text(viewModel.aiPreviewData)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .padding(12)
                .background(.quaternary, in: .rect(cornerRadius: 10))

                HStack {
                    Spacer()
                    Button("Close") {
                        viewModel.aiPreviewVisible = false
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.teal, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(.bottom, 4)

                Text(Product.name)
                    .font(.title)
                    .fontWeight(.bold)

                Text("Version \(viewModel.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Fast file search for macOS")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Glass Section Helper

    /// A section with a subtle glass-style background and rounded corners.
    private func glassSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(16)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
        }
    }

    // MARK: - Status Row Helper

    /// A labeled key-value row with optional color accent.
    private func statusRow(label: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(color)
                .fontWeight(.medium)
        }
        .font(.body)
    }

    // MARK: - Status Badge Helper

    /// A small pill-shaped badge for status indicators.
    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}
