import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - FileDetailView

/// Detail panel showing file metadata for a selected search result.
///
/// REQ-3.2-28: Displays file icon, path with copy button, and a metadata grid
/// (size, type, created, modified, parent directory). Uses Liquid Glass material.
/// Detects deleted files and shows a warning banner.
struct FileDetailView: View {

    let result: SearchResult

    /// Whether the file still exists on disk (checked on appear).
    @State private var fileExists: Bool = true

    /// Tracks whether a value was just copied (for brief visual feedback).
    @State private var copiedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !fileExists {
                fileMissingBanner
            }

            headerSection

            Divider()

            fullPathRow

            Divider()

            metadataGrid
        }
        .padding(16)
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
        .glassEffect()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { checkFileExists() }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(nsImage: largeIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.record.originalName)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(2)

                if let ext = result.record.extension, !ext.isEmpty {
                    Text(ext.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
            }

            Spacer()
        }
    }

    // MARK: - Full Path Row

    private var fullPathRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(result.record.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)

            Spacer()

            copyButton(field: "path", value: result.record.path)
        }
    }

    // MARK: - Metadata Grid

    private var metadataGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataRow(label: "大小", value: FileSizeFormatter.format(result.record.size), field: "size")

            metadataRow(
                label: "类型",
                value: typeDescription,
                field: "type"
            )

            metadataRow(
                label: "创建",
                value: result.record.createdAt.formatted(date: .abbreviated, time: .shortened),
                field: "created"
            )

            metadataRow(
                label: "修改",
                value: result.record.modifiedAt.formatted(date: .abbreviated, time: .shortened),
                field: "modified"
            )

            metadataRow(
                label: "路径",
                value: PathShortener.shorten(result.record.parentPath),
                field: "parent"
            )
        }
    }

    // MARK: - File Missing Banner

    private var fileMissingBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            Text("文件已移除")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Helpers

    /// Human-readable type description from UTType, falling back to extension.
    private var typeDescription: String {
        if result.record.isDirectory {
            return "文件夹"
        }
        if let ext = result.record.extension,
           let utType = UTType(filenameExtension: ext) {
            return utType.localizedDescription ?? ext.uppercased()
        }
        return result.record.extension?.uppercased() ?? "未知"
    }

    /// 48x48 file icon via NSWorkspace (not cached — detail view is shown for one file).
    private var largeIcon: NSImage {
        let icon: NSImage
        if result.record.isDirectory {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else if let ext = result.record.extension,
                  let utType = UTType(filenameExtension: ext) {
            icon = NSWorkspace.shared.icon(for: utType)
        } else {
            icon = NSWorkspace.shared.icon(for: .item)
        }

        let sized = NSImage(size: NSSize(width: 48, height: 48))
        sized.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
        sized.unlockFocus()
        return sized
    }

    private func checkFileExists() {
        fileExists = FileManager.default.fileExists(atPath: result.record.path)
    }

    // MARK: - Sub-views

    private func metadataRow(label: String, value: String, field: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            copyButton(field: field, value: value)
        }
    }

    private func copyButton(field: String, value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedField = field
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if copiedField == field {
                    copiedField = nil
                }
            }
        } label: {
            Image(systemName: copiedField == field ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(copiedField == field ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制")
    }
}
