import SwiftUI
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - SettingsView

/// Settings window content with four tabs: General, Index, AI, About.
public struct SettingsView: View {

    private enum Design {
        public static let privacyBadgeFontSize: CGFloat = 10
        public static let privacyBadgeHPadding: CGFloat = 6
        public static let privacyBadgeVPadding: CGFloat = 2
    }

    public let viewModel: SettingsViewModel

    public var body: some View {
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
        .tabViewStyle(.automatic)
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
                                ExcludedPathRow(path: path) {
                                    Task { await viewModel.removePath(path) }
                                }
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

                        if !viewModel.newPathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("将排除匹配此路径的所有文件")
                                    .font(DeepFinderTypography.metadata(size: 11))
                                    .foregroundStyle(.tertiary)
                                Text(viewModel.newPathText)
                                    .font(DeepFinderTypography.metadata(size: 11))
                                    .foregroundStyle(GlowColors.teal)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.leading, 2)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("路径匹配预览: \(viewModel.newPathText)")
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
                // Privacy notice
                Text("🔒 所有 AI 功能默认关闭。标注为「本地」的功能完全在设备上运行，数据不会离开你的 Mac。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                glassSection("AI 助手") {
                    VStack(spacing: 12) {
                        privacyRail(color: GlowColors.amber.opacity(0.3)) {
                            Toggle(isOn: Binding(
                                get: { viewModel.aiEnabled },
                                set: { newValue in Task { await viewModel.setAIEnabled(newValue) } }
                            )) {
                                HStack(spacing: 6) {
                                    Text("启用 AI 助手")
                                    cloudBadge
                                }
                            }
                        }

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
                    privacyRail(color: GlowColors.amber.opacity(0.3)) {
                        HStack(spacing: 6) {
                            SecureField("API 密钥", text: Binding(
                                get: { viewModel.aiAPIKeyText },
                                set: { newValue in
                                    viewModel.aiAPIKeyText = newValue
                                    Task { await viewModel.setAIKey(newValue) }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .disabled(!viewModel.aiEnabled)
                            cloudBadge
                        }
                    }
                }

                glassSection("隐私") {
                    VStack(spacing: 12) {
                        privacyRail(color: GlowColors.amber.opacity(0.3)) {
                            Toggle(isOn: Binding(
                                get: { viewModel.aiSendMetadata },
                                set: { newValue in Task { await viewModel.setAISendMetadata(newValue) } }
                            )) {
                                HStack(spacing: 6) {
                                    Text("发送元数据到云端")
                                    cloudBadge
                                }
                            }
                            .disabled(!viewModel.aiEnabled)
                        }

                        Toggle("路径匿名化", isOn: Binding(
                            get: { viewModel.aiPathAnonymization },
                            set: { newValue in Task { await viewModel.setAIPathAnonymization(newValue) } }
                        ))
                    }
                }

                glassSection("本地功能") {
                    privacyRail(color: GlowColors.teal.opacity(0.3)) {
                        Toggle(isOn: Binding(
                            get: { viewModel.aiLocalVision },
                            set: { newValue in Task { await viewModel.setAILocalVision(newValue) } }
                        )) {
                            HStack(spacing: 6) {
                                Text("本地视觉分析")
                                localBadge
                            }
                        }
                    }
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
                        RoundedRectangle(cornerRadius: 14)
                            .fill(
                                LinearGradient(
                                    colors: [GlowColors.teal, GlowColors.violet],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 72, height: 72)
                            .shadow(color: GlowColors.teal.opacity(0.2), radius: 20, y: 4)
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.white)
                    }

                    Text(Product.name)
                        .font(DeepFinderTypography.heading(size: 22))

                    Text("Version \(viewModel.version)")
                        .font(DeepFinderTypography.metadata(size: 13))
                        .foregroundStyle(.secondary)

                    Text("macOS 快速文件搜索工具")
                        .font(DeepFinderTypography.body(size: 13))
                        .foregroundStyle(.tertiary)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [GlowColors.teal, GlowColors.violet, GlowColors.coral, GlowColors.amber],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1.5)
                        .shadow(color: GlowColors.violet.opacity(0.15), radius: 4, y: 1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)

                    HStack(spacing: 16) {
                        settingsLink("GitHub", url: "https://github.com/nadav-cheung/DeepFinder")
                        settingsLink("问题反馈", url: "https://github.com/nadav-cheung/DeepFinder/issues")
                        settingsLink("文档", url: "https://github.com/nadav-cheung/DeepFinder#readme")
                    }
                }
                .padding(24)
            }

            // Share / recommend section
            VStack(alignment: .leading, spacing: 12) {
                Text("推荐给朋友")
                    .font(DeepFinderTypography.subheading(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                SharePromptView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
                .font(DeepFinderTypography.subheading(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(18)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.3), lineWidth: 0.5)
            )
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
            .animation(.spring(duration: 0.3, bounce: 0.15), value: color.description)
    }

    // MARK: - Privacy Rail Helper

    /// Wraps content in a row with a thin colored left border (privacy rail).
    private func privacyRail<Content: View>(
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
                .shadow(color: color.opacity(0.2), radius: 3)
            content()
                .padding(.leading, 10)
        }
    }

    // MARK: - Settings Link Helper

    /// A styled link for the About tab with hover brightening.
    private func settingsLink(_ title: String, url: String) -> some View {
        SettingsLinkRow(title: title, url: url)
    }

    // MARK: - Privacy Badge Helpers

    /// Badge indicating on-device (local) processing.
    private var localBadge: some View {
        Text("本地")
            .font(.system(size: Design.privacyBadgeFontSize, weight: .medium))
            .foregroundStyle(GlowColors.teal)
            .padding(.horizontal, Design.privacyBadgeHPadding)
            .padding(.vertical, Design.privacyBadgeVPadding)
            .background(GlowColors.teal.opacity(0.12), in: Capsule())
            .accessibilityLabel("本地处理")
    }

    /// Badge indicating cloud-based processing.
    private var cloudBadge: some View {
        Text("云端")
            .font(.system(size: Design.privacyBadgeFontSize, weight: .medium))
            .foregroundStyle(GlowColors.amber)
            .padding(.horizontal, Design.privacyBadgeHPadding)
            .padding(.vertical, Design.privacyBadgeVPadding)
            .background(GlowColors.amber.opacity(0.12), in: Capsule())
            .accessibilityLabel("云端处理")
    }
}

// MARK: - Excluded Path Row

/// A single excluded path row with hover background.
private struct ExcludedPathRow: View {
    public let path: String
    public let onRemove: () -> Void

    @State private var isHovered = false

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.minus")
                .foregroundStyle(.secondary)
                .font(.callout)
            Text(path)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(path)")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(isHovered ? 0.3 : 0))
        )
        .animation(.spring(duration: 0.25, bounce: 0.1), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Settings Link Row

/// A styled link with underline on hover for the About tab.
private struct SettingsLinkRow: View {
    public let title: String
    public let url: String

    @State private var isHovered = false

    public var body: some View {
        Link(title, destination: URL(string: url)!)
            .font(DeepFinderTypography.badge(size: 12))
            .foregroundStyle(.secondary)
            .underline(isHovered)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
