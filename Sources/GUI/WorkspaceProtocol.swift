// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import AppKit
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - WorkspaceProtocol

/// Protocol abstracting NSWorkspace operations for testability.
///
/// Production uses `NSWorkspace.default`. Tests inject `MockWorkspace`
/// to verify open/reveal behavior without touching the real file system.
///
/// `@MainActor` because NSWorkspace operations must run on the main thread.
@MainActor
public protocol WorkspaceProtocol: Sendable {
    func open(_ path: String) -> Bool
    func selectFile(_ path: String) -> Bool
}

// MARK: - NSWorkspace + WorkspaceProtocol

extension NSWorkspace: WorkspaceProtocol {
    public nonisolated func open(_ path: String) -> Bool {
        open(URL(fileURLWithPath: path))
    }

    public nonisolated func selectFile(_ path: String) -> Bool {
        selectFile(path, inFileViewerRootedAtPath: "")
    }
}
