import Foundation
import AppKit

// MARK: - WorkspaceProtocol

/// Protocol abstracting NSWorkspace operations for testability.
///
/// Production uses `NSWorkspace.default`. Tests inject `MockWorkspace`
/// to verify open/reveal behavior without touching the real file system.
///
/// `@MainActor` because NSWorkspace operations must run on the main thread.
@MainActor
protocol WorkspaceProtocol: Sendable {
    func open(_ path: String) -> Bool
    func selectFile(_ path: String) -> Bool
}

// MARK: - NSWorkspace + WorkspaceProtocol

extension NSWorkspace: WorkspaceProtocol {
    nonisolated func open(_ path: String) -> Bool {
        open(URL(fileURLWithPath: path))
    }

    nonisolated func selectFile(_ path: String) -> Bool {
        selectFile(path, inFileViewerRootedAtPath: "")
    }
}
