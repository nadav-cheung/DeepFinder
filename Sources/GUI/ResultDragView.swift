// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import SwiftUI
import AppKit
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - DragItemProvider

/// Protocol abstracting drag-item creation for testability.
///
/// Production uses `NSItemProvider` with file URLs. Tests inject
/// `MockDragItemProvider` to verify drag payload logic without
/// touching the pasteboard.
public protocol DragItemProvider: Sendable {
    /// Create a drag item provider for the file at the given path.
    func itemProvider(forFileAt path: String) -> NSItemProvider
}

// MARK: - DefaultDragItemProvider

/// Default production implementation: creates an `NSItemProvider` with a file URL.
///
/// The resulting drag payload can be dropped into Finder (to copy/move), Terminal
/// (to paste the path), or any app that accepts file URLs.
@MainActor
final public class DefaultDragItemProvider: DragItemProvider, @unchecked Sendable {
    public init() {}

    public nonisolated func itemProvider(forFileAt path: String) -> NSItemProvider {
        let url = URL(fileURLWithPath: path)
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

// MARK: - ResultDragViewModifier

/// View modifier that attaches drag support to a result row.
///
/// REQ-2.0-13: Drag support via `.onDrag` modifier on result rows. Provides
/// the file URL via `NSItemProvider` so results can be dragged to Finder,
/// Terminal, or any app accepting file URLs.
public struct ResultDragViewModifier: ViewModifier {

    public let path: String
    public let dragProvider: any DragItemProvider

    public func body(content: Content) -> some View {
        content.onDrag {
            self.dragProvider.itemProvider(forFileAt: self.path)
        }
    }
}

// MARK: - View extension

extension View {

    /// Attach drag support for a file result.
    ///
    /// Wraps `.onDrag` with a testable `DragItemProvider`. In production the
    /// default provider creates an `NSItemProvider` from a file URL. In tests
    /// a mock provider can be injected to verify the path being dragged.
    @MainActor
    public func resultDrag(path: String, provider: any DragItemProvider = DefaultDragItemProvider()) -> some View {
        modifier(ResultDragViewModifier(path: path, dragProvider: provider))
    }
}
