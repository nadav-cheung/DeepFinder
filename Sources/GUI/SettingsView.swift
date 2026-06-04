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
                    Label("通用", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            indexTab
                .tabItem {
                    Label("索引", systemImage: "doc.text.magnifyingglass")
                }
                .tag(SettingsTab.index)

            aiTab
                .tabItem {
                    Label("AI", systemImage: "brain")
                }
                .tag(SettingsTab.ai)

            aboutTab
                .tabItem {
                    Label("关于", systemImage: "info.circle")
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
                glassSection("全局快捷键") {
                    HStack {
                        Text("全局快捷键")
                            .font(.body)
                        Spacer()
                        Text(viewModel.hotkeyDisplay)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: .rect(cornerRadius: 6))
                        Button("恢复默认") {
                            viewModel.resetHotkeyDisplay()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                glassSection("开机启动") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("开机时启动", isOn: Binding(
                                get: { viewModel.autoLaunchEnabled },
                                set: { newValue in Task { await viewModel.setAutoLaunch(newValue) } }
                            ))
                            Spacer()
                            statusBadge(
                                text: viewModel.autoLaunchEnabled ? "已启用" : "已禁用",
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

                glassSection("排除路径") {
                    VStack(alignment: .leading, spacing: 10) {
                        if viewModel.excludedPaths.isEmpty {
                            Text("无排除路径")
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
                            TextField("输入要排除的路径", text: $vm.newPathText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button("添加") {
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

                glassSection("权限") {
                    VStack(spacing: 10) {
                        HStack {
                            Text("完全磁盘访问")
                                .font(.body)
                            Spacer()
                            statusBadge(
                                text: viewModel.fdaGranted ? "已授权" : "未授权",
                                color: viewModel.fdaGranted ? .green : .red
                            )
                        }

                        Divider()

                        HStack {
                            Text("辅助功能")
                                .font(.body)
                            Spacer()
                            statusBadge(
                                text: viewModel.accessibilityGranted ? "已授权" : "未授权",
                                color: viewModel.accessibilityGranted ? .green : .red
                            )
                        }

                        Divider()

                        HStack {
                            Spacer()
                            Button("打开系统设置") {
                                PermissionChecker.openFDASettings()
                            }
                            .buttonStyle(.bordered)
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
                glassSection("索引状态") {
                    if let stats = viewModel.indexStats {
                        VStack(spacing: 10) {
                            statusRow(
                                label: "状态",
                                value: stats.state.capitalized,
                                color: stats.state == "live" ? .green : .orange
                            )
                            Divider()
                            statusRow(
                                label: "已索引文件",
                                value: stats.filesIndexed.formatted()
                            )
                            if let date = stats.lastScanDate {
                                Divider()
                                statusRow(
                                    label: "上次扫描",
                                    value: date.formatted(.dateTime)
                                )
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("加载中...")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }

                glassSection("维护") {
                    VStack(spacing: 12) {
                        HStack {
                            Button("重建索引") {
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
                                Text("正在重建索引...")
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
                glassSection("AI 助手") {
                    VStack(spacing: 12) {
                        Toggle("启用 AI 助手", isOn: Binding(
                            get: { viewModel.aiEnabled },
                            set: { newValue in Task { await viewModel.setAIEnabled(newValue) } }
                        ))

                        Picker("模型", selection: Binding(
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

                glassSection("API 密钥") {
                    SecureField("API 密钥", text: Binding(
                        get: { viewModel.aiAPIKeyText },
                        set: { newValue in
                            viewModel.aiAPIKeyText = newValue
                            Task { await viewModel.setAIKey(newValue) }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!viewModel.aiEnabled)
                }

                glassSection("隐私") {
                    VStack(spacing: 12) {
                        Toggle("发送元数据到云端", isOn: Binding(
                            get: { viewModel.aiSendMetadata },
                            set: { newValue in Task { await viewModel.setAISendMetadata(newValue) } }
                        ))
                        .disabled(!viewModel.aiEnabled)

                        Toggle("路径匿名化", isOn: Binding(
                            get: { viewModel.aiPathAnonymization },
                            set: { newValue in Task { await viewModel.setAIPathAnonymization(newValue) } }
                        ))
                    }
                }

                glassSection("本地功能") {
                    Toggle("本地视觉分析", isOn: Binding(
                        get: { viewModel.aiLocalVision },
                        set: { newValue in Task { await viewModel.setAILocalVision(newValue) } }
                    ))
                }

                glassSection("诊断") {
                    Button("预览数据") {
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
                    Text("AI 数据预览")
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
                    Button("关闭") {
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

            GlassEffectContainer(intensity: .clear, cornerRadius: 16, borderWidth: nil) {
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
                                LinearGradient(
                                    colors: [GlowColors.teal, GlowColors.violet],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 64, height: 64)
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white)
                    }

                    Text(Product.name)
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Version \(viewModel.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("macOS 快速文件搜索工具")
                        .font(.body)
                        .foregroundStyle(.tertiary)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [GlowColors.teal, GlowColors.violet, GlowColors.coral, GlowColors.amber],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)

                    HStack(spacing: 16) {
                        Link("GitHub", destination: URL(string: "https://github.com/nadav-cheung/DeepFinder")!)
                        Link("问题反馈", destination: URL(string: "https://github.com/nadav-cheung/DeepFinder/issues")!)
                        Link("文档", destination: URL(string: "https://github.com/nadav-cheung/DeepFinder#readme")!)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
            }

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
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
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
