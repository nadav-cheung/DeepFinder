// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderMedia
import DeepFinderCLILib

// MARK: - FileDetailView

/// Detail panel showing file metadata for a selected search result.
///
/// REQ-3.2-28: Displays file icon, path with copy button, and a metadata grid
/// (size, type, created, modified, parent directory). Uses Liquid Glass material.
/// Detects deleted files and shows a warning banner.
public struct FileDetailView: View {

    public let result: SearchResult

    /// Whether the file still exists on disk (checked on appear).
    @State private var fileExists: Bool = true

    /// Tracks whether a value was just copied (for brief visual feedback).
    @State private var copiedField: String?

    /// Controls the entrance animation.
    @State private var appeared: Bool = false

    /// Lazily-extracted media metadata (image dimensions, audio duration, PDF page count, …).
    /// Populated on demand via ``MetadataLoader`` when the panel is shown for a media file.
    @State private var mediaMetadata: ExtractedMetadata?

    /// True while media metadata is being extracted off the main thread.
    @State private var isExtractingMetadata: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !fileExists {
                fileMissingBanner
            }

            headerSection

            Divider()

            fullPathRow

            Divider()

            metadataGrid

            if isExtractingMetadata || mediaMetadata != nil {
                Divider()

                mediaMetadataSection
            }
        }
        .padding(16)
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
        .glassEffect()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : 20)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appeared)
        .onAppear {
            checkFileExists()
            appeared = true
        }
        .task(id: result.record.path) {
            await loadMediaMetadata()
        }
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
        let rows: [(String, String, String)] = [
            ("大小", FileSizeFormatter.format(result.record.size), "size"),
            ("类型", typeDescription, "type"),
            ("创建", result.record.createdAt.formatted(date: .abbreviated, time: .shortened), "created"),
            ("修改", result.record.modifiedAt.formatted(date: .abbreviated, time: .shortened), "modified"),
            ("路径", PathShortener.shorten(result.record.parentPath), "parent")
        ]

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                metadataRow(label: row.0, value: row.1, field: row.2)

                if index < rows.count - 1 {
                    Divider().opacity(0.2).padding(.vertical, 5)
                }
            }
        }
    }

    // MARK: - Media Metadata Section

    /// On-demand media metadata (dimensions, duration, page count, …) extracted via
    /// ``MetadataLoader``. Shown only for media files; non-media files produce `nil`
    /// and this section stays hidden.
    private var mediaMetadataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("媒体信息")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            if isExtractingMetadata {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let metadata = mediaMetadata {
                let rows = formattedMediaRows(from: metadata)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    metadataRow(label: row.0, value: row.1, field: "media-\(index)")
                    if index < rows.count - 1 {
                        Divider().opacity(0.2).padding(.vertical, 5)
                    }
                }
            }
        }
    }

    /// Extract media metadata off the main thread when a media file is shown.
    /// Reuses the shared ``MetadataLoader`` cache, so re-displaying a file is instant.
    private func loadMediaMetadata() async {
        // Directories and missing files have no media metadata.
        guard !result.record.isDirectory,
              FileManager.default.fileExists(atPath: result.record.path) else {
            mediaMetadata = nil
            isExtractingMetadata = false
            return
        }
        isExtractingMetadata = true
        let url = URL(fileURLWithPath: result.record.path)
        mediaMetadata = await MetadataLoader.shared.metadata(
            for: url,
            fileExtension: result.record.extension
        )
        isExtractingMetadata = false
    }

    /// Render extracted metadata fields as friendly localized label/value rows.
    /// Special-cases composite values (dimensions, duration, bit rate); everything else
    /// maps through a fixed key → label table.
    private func formattedMediaRows(from metadata: ExtractedMetadata) -> [(String, String)] {
        let fields = metadata.fields
        var rows: [(String, String)] = []

        if let width = fields["width"]?.intValue, let height = fields["height"]?.intValue {
            rows.append(("尺寸", "\(width) × \(height)"))
        }
        if let duration = fields["duration"]?.doubleValue {
            rows.append(("时长", Self.formatDuration(duration)))
        }
        if let pages = fields["pageCount"]?.intValue {
            rows.append(("页数", "\(pages)"))
        }

        let stringLabels: [(key: String, label: String)] = [
            ("title", "标题"), ("artist", "艺术家"), ("album", "专辑"),
            ("author", "作者"), ("creator", "创建者"), ("genre", "流派"),
            ("subject", "主题"), ("codec", "编码"), ("audioCodec", "编码"),
            ("colorSpace", "色彩空间"),
        ]
        for entry in stringLabels {
            if let value = fields[entry.key]?.stringValue, !value.isEmpty {
                rows.append((entry.label, value))
            }
        }

        if let dpi = fields["dpi"]?.intValue { rows.append(("DPI", "\(dpi)")) }
        if let bitRate = fields["bitRate"]?.intValue, bitRate > 0 {
            rows.append(("比特率", "\(bitRate / 1000) kbps"))
        }
        if let sampleRate = fields["sampleRate"]?.intValue, sampleRate > 0 {
            rows.append(("采样率", "\(sampleRate / 1000) kHz"))
        }
        if let channels = fields["channels"]?.intValue {
            rows.append(("声道", "\(channels)"))
        }
        if let fps = fields["fps"]?.doubleValue {
            rows.append(("帧率", String(format: "%.1f fps", fps)))
        }
        if let year = fields["year"]?.intValue {
            rows.append(("年份", "\(year)"))
        }
        if let date = fields["dateTaken"]?.dateValue {
            rows.append(("拍摄时间", date.formatted(date: .abbreviated, time: .shortened)))
        } else if let date = fields["creationDate"]?.dateValue {
            rows.append(("创建时间", date.formatted(date: .abbreviated, time: .shortened)))
        }

        return rows
    }

    /// Format a duration in seconds as `m:ss` or `h:mm:ss`.
    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - File Missing Banner

    private var fileMissingBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .symbolEffect(.pulse, options: .repeating, isActive: !fileExists)

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
        .padding(.vertical, 4)
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
        .buttonStyle(ScalePressButtonStyle())
        .accessibilityLabel("复制")
    }
}

// MARK: - ScalePressButtonStyle

/// A button style that scales down on press with a spring animation.
private struct ScalePressButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.5), value: configuration.isPressed)
    }
}
