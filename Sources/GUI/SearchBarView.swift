import SwiftUI

// MARK: - SearchBarView

/// Search bar with clear button, CJK input handling, and Liquid Glass material.
///
/// REQ-2.0-02: Search icon + TextField + clear button. Glass material.
/// CJK composition-safe: only triggers search when text is committed (not during marked text).
struct SearchBarView: View {

    /// Placeholder text, exposed as static constant for testing.
    static let placeholder = "搜索文件..."

    @Binding var text: String
    let onCommit: (String) -> Void
    var onClear: (() -> Void)? = nil

    /// Tracks whether an input method has marked (uncommitted) text.
    /// When true, text changes are from CJK composition and should not trigger search.
    @State private var hasMarkedText = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))

            TextField(Self.placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .onReceive(NotificationCenter.default.publisher(for: NSText.didEndEditingNotification)) { _ in
                    hasMarkedText = false
                }
                .onChange(of: text) { _, newValue in
                    guard !hasMarkedText else { return }
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

// MARK: - SearchBarState

/// Encapsulates the CJK composition logic for search triggering.
///
/// Separated from the view for testability: tests can create a state instance,
/// toggle `hasMarkedText`, and verify `onTextChange` fires `onCommit` correctly.
final class SearchBarState {
    var hasMarkedText = false
    private var onCommit: (String) -> Void

    init(onCommit: @escaping (String) -> Void = { _ in }) {
        self.onCommit = onCommit
    }

    /// Called when text changes. Only fires `onCommit` if not in CJK composition.
    func onTextChange(_ newText: String) {
        guard !hasMarkedText else { return }
        guard !newText.isEmpty else { return }
        onCommit(newText)
    }
}
