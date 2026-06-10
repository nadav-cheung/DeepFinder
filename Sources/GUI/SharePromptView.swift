import SwiftUI
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - SharePromptView

/// Compact card encouraging users to share or recommend DeepFinder.
///
/// Shows a one-line value proposition with a copy-to-clipboard button and links
/// to the GitHub repository and releases page. An optional dismiss button is
/// displayed when `onDismiss` is provided.
///
/// Fits in the Settings About tab at ~400 pt max width.
public struct SharePromptView: View {

    /// Called when the user taps the dismiss (X) button. When `nil`, the button is hidden.
    public var onDismiss: (() -> Void)? = nil

    // MARK: - State

    @State private var didCopy = false
    @State private var copyPressed = false
    @State private var starLinkHovered = false
    @State private var releasesLinkHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Design Tokens

    private enum Design {
        public static let cornerRadius: CGFloat = 12
        public static let gradientHeight: CGFloat = 1
        public static let hPadding: CGFloat = 16
        public static let vPadding: CGFloat = 14
        public static let spacing: CGFloat = 10
        public static let titleSize: CGFloat = 15
        public static let bodySize: CGFloat = 13
        public static let maxW: CGFloat = 400

        public static let valueProp = "macOS 最快的文件搜索工具 — 毫秒级全盘搜索，免费开源"
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Signature gradient line at top
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [GlowColors.teal, GlowColors.violet, GlowColors.coral],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: Design.gradientHeight)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

            content
                .padding(.horizontal, Design.hPadding)
                .padding(.vertical, Design.vPadding)
        }
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Design.cornerRadius))
        .frame(maxWidth: Design.maxW)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("推荐 \(Product.name)")
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: Design.spacing) {
            header
            copyButton
            linkRow
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("推荐给朋友")
                    .font(DeepFinderTypography.subheading(size: Design.titleSize))
                Text(Design.valueProp)
                    .font(DeepFinderTypography.body(size: Design.bodySize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let onDismiss {
                Button {
                    withAnimation(DeepFinderMotion.springSmooth) {
                        onDismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭推荐卡片")
            }
        }
    }

    // MARK: - Copy Button

    private var copyButton: some View {
        HStack {
            Spacer()
            Button {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Design.valueProp, forType: .string)
                #endif
                withAnimation(DeepFinderMotion.springSnappy) {
                    didCopy = true
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(DeepFinderMotion.springSnappy) {
                        didCopy = false
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                    Text(didCopy ? "已复制" : "复制文案")
                        .font(DeepFinderTypography.badge(size: 11))
                }
                .foregroundStyle(didCopy ? GlowColors.teal : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    didCopy
                        ? GlowColors.teal.opacity(0.12)
                        : Color(nsColor: .quaternaryLabelColor),
                    in: .rect(cornerRadius: 6)
                )
                .scaleEffect(copyPressed ? 0.95 : 1.0)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in withAnimation(DeepFinderMotion.springSnappy) { copyPressed = true } }
                    .onEnded { _ in withAnimation(DeepFinderMotion.springSnappy) { copyPressed = false } }
            )
            .accessibilityLabel(didCopy ? "已复制到剪贴板" : "复制推荐文案到剪贴板")
        }
    }

    // MARK: - Link Row

    private var linkRow: some View {
        HStack(spacing: 14) {
            Link(destination: URL(string: "https://github.com/nadav-cheung/DeepFinder")!) {
                HStack(spacing: 4) {
                    Image(systemName: "star")
                        .font(.system(size: 11))
                    Text("GitHub Star")
                        .font(DeepFinderTypography.badge(size: 11))
                }
                .foregroundStyle(GlowColors.amber)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .brightness(starLinkHovered ? 0.15 : 0)
                .contentShape(.rect(cornerRadius: 6))
            }
            .onHover { starLinkHovered = $0 }
            .animation(.spring(duration: 0.25, bounce: 0.1), value: starLinkHovered)
            .accessibilityLabel("\(Product.name) GitHub 页面，点按加星标")

            Link(destination: URL(string: "https://github.com/nadav-cheung/DeepFinder/releases")!) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                    Text("下载页")
                        .font(DeepFinderTypography.badge(size: 11))
                }
                .foregroundStyle(GlowColors.violet)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .brightness(releasesLinkHovered ? 0.15 : 0)
                .contentShape(.rect(cornerRadius: 6))
            }
            .onHover { releasesLinkHovered = $0 }
            .animation(.spring(duration: 0.25, bounce: 0.1), value: releasesLinkHovered)
            .accessibilityLabel("\(Product.name) 下载页")

            Spacer()
        }
    }
}
