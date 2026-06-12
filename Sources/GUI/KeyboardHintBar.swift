// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import SwiftUI
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - KeyboardHintBar

/// A thin horizontal bar displaying keyboard shortcut hints for result actions.
///
/// REQ-3.2-06: Shows a compact row of shortcut labels separated by thin dividers.
/// Shortcut symbols use monospaced design for alignment; descriptive text uses
/// the system font at size 11 in secondary color.
public struct KeyboardHintBar: View {

    // MARK: - Hint Model

    fileprivate struct Hint: Identifiable {
        public let symbol: String
        public let label: String
        public var id: String { symbol + label }
    }

    // MARK: - REQ-3.2-37: Testable hint count

    /// Number of hints displayed. Exposed for testing.
    public static let expectedHintCount = 6

    // MARK: - Hints

    private let hints: [Hint] = [
        Hint(symbol: "↵", label: "打开"),
        Hint(symbol: "⌘↵", label: "Finder"),
        Hint(symbol: "Space", label: "预览"),
        Hint(symbol: "⌘C", label: "路径"),
        Hint(symbol: "⌘K", label: "操作"),
        Hint(symbol: "⌘I", label: "详情")   // REQ-3.2-37
    ]

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)

            HStack(spacing: 0) {
                ForEach(Array(hints.enumerated()), id: \.element.id) { index, hint in
                    if index > 0 {
                        Rectangle()
                            .fill(.separator)
                            .frame(width: 1, height: 10)
                            .padding(.horizontal, 6)
                    }

                    HintItem(hint: hint)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - HintItem

/// A single keyboard shortcut hint with elevated key background and hover brightness.
private struct HintItem: View {
    public let hint: KeyboardHintBar.Hint

    @State private var isHovered = false

    public var body: some View {
        HStack(spacing: 3) {
            Text(hint.symbol)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            Text(hint.label)
        }
        .brightness(isHovered ? 0.15 : 0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
