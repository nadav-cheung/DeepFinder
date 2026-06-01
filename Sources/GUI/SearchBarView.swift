import SwiftUI

// MARK: - SearchBarView

/// Search bar with clear button and Liquid Glass material.
///
/// REQ-2.0-02: Search icon + TextField + clear button. Glass material.
/// SwiftUI TextField handles CJK input composition internally — the text binding
/// only updates when composed text is committed, so no explicit marked-text guard is needed.
struct SearchBarView: View {

    /// Placeholder text, exposed as static constant for testing.
    static let placeholder = "搜索文件..."

    @Binding var text: String
    let onCommit: (String) -> Void
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))

            TextField(Self.placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .onChange(of: text) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    onCommit(newValue)
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.placeholder)
    }
}
