// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import SwiftUI
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - FileAction

/// Actions available in the action panel for a selected file result.
///
/// Extends the context menu actions with Quick Look and Trash, providing
/// a keyboard-navigable panel alternative to the right-click menu.
public enum FileAction: String, CaseIterable, Identifiable, Sendable {
    case open
    case reveal
    case copyPath
    case quickLook
    case getInfo
    case trash

    public var id: String { rawValue }

    /// SF Symbol icon for the action.
    public var icon: String {
        switch self {
        case .open:      "arrow.down.doc"
        case .reveal:    "folder"
        case .copyPath:  "doc.on.doc"
        case .quickLook: "eye"
        case .getInfo:   "info.circle"
        case .trash:     "trash"
        }
    }

    /// Localized display title.
    public var title: String {
        switch self {
        case .open:      "打开"
        case .reveal:    "在 Finder 中显示"
        case .copyPath:  "拷贝路径"
        case .quickLook: "快速查看"
        case .getInfo:   "显示简介"
        case .trash:     "移到废纸篓"
        }
    }

    /// Keyboard shortcut string displayed in the row.
    public var shortcut: String {
        switch self {
        case .open:      "↵"
        case .reveal:    "⌘↵"
        case .copyPath:  "⌘C"
        case .quickLook: "Space"
        case .getInfo:   "⌘I"
        case .trash:     "⌘⌫"
        }
    }
}

// MARK: - ActionPanelView

/// Keyboard-navigable action panel for file operations.
///
/// REQ-3.2-31: A glass-effect panel listing file actions with icons, titles,
/// and keyboard shortcuts. Supports search filtering, up/down arrow navigation,
/// Enter to execute, and Escape to dismiss.
///
/// Max height is capped at 300pt. Each row displays an SF Symbol icon, title,
/// and shortcut in secondary color. The panel uses `GlassEffectContainer` for
/// the Liquid Glass background with a 16pt corner radius.
public struct ActionPanelView: View {

    /// Called when the user activates an action via Enter key or click.
    public let onAction: (FileAction) -> Void

    // MARK: - State

    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0
    @State private var hoveredActionID: String?
    @FocusState private var isSearchFocused: Bool

    // MARK: - Constants

    private static let maxHeight: CGFloat = 300

    // MARK: - Derived

    /// Actions filtered by current search text.
    private var filteredActions: [FileAction] {
        guard !searchText.isEmpty else { return FileAction.allCases }
        return FileAction.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Safe index clamped to the filtered list bounds.
    private var clampedIndex: Int {
        let count = filteredActions.count
        guard count > 0 else { return 0 }
        return min(max(selectedIndex, 0), count - 1)
    }

    // MARK: - Body

    public var body: some View {
        GlassEffectContainer(
            intensity: .regular,
            cornerRadius: 16,
            borderWidth: nil
        ) {
            VStack(spacing: 0) {
                searchField
                Divider()
                actionList
            }
        }
        .frame(maxHeight: Self.maxHeight)
        .onKeyPress(.upArrow) { handleUp(); return .handled }
        .onKeyPress(.downArrow) { handleDown(); return .handled }
        .onKeyPress(.return) { handleEnter(); return .handled }
        .onKeyPress(.escape) { handleEscape(); return .handled }
    }

    // MARK: - Subviews

    private var searchField: some View {
        TextField("过滤操作...", text: $searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .focused($isSearchFocused)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(isSearchFocused ? 0.08 : 0))
                    .animation(.easeOut(duration: 0.2), value: isSearchFocused)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isSearchFocused ? 0.3 : 0), lineWidth: 1)
                    .animation(.easeOut(duration: 0.2), value: isSearchFocused)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            )
            .onAppear { isSearchFocused = true }
            .onChange(of: searchText) { _, _ in
                selectedIndex = 0
            }
    }

    private var actionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filteredActions.enumerated()), id: \.element.id) { index, action in
                    actionRow(action: action, isSelected: index == clampedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = index
                            onAction(action)
                        }

                    if index < filteredActions.count - 1 {
                        Divider().opacity(0.2)
                    }
                }
            }
        }
    }

    private func actionRow(action: FileAction, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(hoveredActionID == action.id ? 0.08 : 0))
                    .frame(width: 26, height: 26)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hoveredActionID)

                Image(systemName: action.icon)
                    .font(.system(size: 13))
            }
            .frame(width: 26)

            Text(action.title)
                .font(.system(size: 13))

            Spacer()

            Text(action.shortcut)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        .onHover { hovering in
            hoveredActionID = hovering ? action.id : nil
        }
    }

    // MARK: - Keyboard Handlers

    private func handleUp() {
        guard !filteredActions.isEmpty else { return }
        selectedIndex = clampedIndex > 0 ? clampedIndex - 1 : filteredActions.count - 1
    }

    private func handleDown() {
        guard !filteredActions.isEmpty else { return }
        selectedIndex = clampedIndex < filteredActions.count - 1 ? clampedIndex + 1 : 0
    }

    private func handleEnter() {
        guard !filteredActions.isEmpty else { return }
        onAction(filteredActions[clampedIndex])
    }

    private func handleEscape() {
        // Dismiss is handled by the parent view observing focus state.
        // This handler consumes the key event so it doesn't propagate.
    }
}
