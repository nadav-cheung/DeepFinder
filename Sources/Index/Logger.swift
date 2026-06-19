// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation

// MARK: - LogLevel

/// Severity level for log messages.
public enum LogLevel: Int, Sendable, Comparable, CustomStringConvertible {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        }
    }
}

// MARK: - Logger

/// Simple file + stderr logger for beta debugging.
///
/// Thread-safe via a serial dispatch queue. Logs to:
/// - `~/.deep-finder/logs/deepfinder.log` (rotating: 10 MB × 5 files)
/// - stderr when `stderrEnabled` is true (controlled by `--debug` flag)
///
/// Usage:
/// ```swift
/// Logger.shared.info("daemon", "starting scan of \(path)")
/// Logger.shared.debug("search", "query='\(q)' limit=\(limit)")
/// Logger.shared.error("ipc", "connection failed: \(error)")
/// ```
public final class Logger: @unchecked Sendable {
    public static let shared = Logger()

    /// Minimum level to emit. Messages below this are dropped.
    /// Access only via queue to ensure thread safety.
    private var _level: LogLevel = .info

    /// Whether to also write to stderr.
    /// Access only via queue to ensure thread safety.
    private var _stderrEnabled = false

    /// Maximum log file size in bytes before rotation (10 MB).
    private static let maxFileSize: Int64 = 10_000_000

    /// Number of rotated backup files to keep.
    private static let maxBackupCount = 5

    /// Queue for serializing all I/O.
    private let queue = DispatchQueue(label: "cn.com.nadav.deepfinder.logger", qos: .utility)

    /// File handle for the current log file.
    private var fileHandle: FileHandle?
    private var currentFilePath: String = ""
    private var currentFileSize: Int64 = 0

    /// ISO 8601 timestamp formatter (reused).
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        return f
    }()

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Configure the logger with a log directory.
    ///
    /// - Parameter logDir: Directory path to store log files (created if needed).
    public func configure(logDir: String) {
        queue.sync {
            let dir = (logDir as NSString).expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/deepfinder.log"
            openFile(path)
        }
    }

    /// Enable or disable stderr output.
    public func setStderrEnabled(_ enabled: Bool) {
        queue.sync { self._stderrEnabled = enabled }
    }

    /// Set the minimum log level.
    public func setLevel(_ newLevel: LogLevel) {
        queue.sync { self._level = newLevel }
    }

    /// Log a debug-level message (only emitted when level <= .debug).
    public func debug(_ component: String, _ message: String) {
        log(level: .debug, component: component, message: message)
    }

    /// Log an info-level message.
    public func info(_ component: String, _ message: String) {
        log(level: .info, component: component, message: message)
    }

    /// Log a warning-level message.
    public func warn(_ component: String, _ message: String) {
        log(level: .warn, component: component, message: message)
    }

    /// Log an error-level message.
    public func error(_ component: String, _ message: String) {
        log(level: .error, component: component, message: message)
    }

    /// Flush buffered writes to disk.
    public func flush() {
        queue.sync {
            fileHandle?.synchronizeFile()
        }
    }

    // MARK: - Private

    private func log(level msgLevel: LogLevel, component: String, message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard msgLevel >= self._level else { return }

            let timestamp = self.dateFormatter.string(from: Date())
            let line = "[\(timestamp)] [\(msgLevel.description)] [\(component)] \(message)\n"

            // Write to stderr if enabled
            if self._stderrEnabled {
                FileHandle.standardError.write(Data(line.utf8))
            }

            // Write to log file
            self.writeToFile(line)
        }
    }

    private func writeToFile(_ line: String) {
        guard let fh = fileHandle else { return }
        let data = Data(line.utf8)
        do {
            try fh.write(contentsOf: data)
        } catch {
            // Log file write failed — try reopen and retry once
            reopenFile()
            do {
                try fileHandle?.write(contentsOf: data)
            } catch {
                // Silently drop; can't log about failing to log
            }
            return
        }
        currentFileSize += Int64(data.count)
        if currentFileSize > Self.maxFileSize {
            rotateFile()
        }
    }

    private func openFile(_ path: String) {
        fileHandle?.closeFile()
        currentFilePath = path

        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        let fh = FileHandle(forWritingAtPath: path) ?? FileHandle()
        fh.seekToEndOfFile()
        fileHandle = fh

        // Get current size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            currentFileSize = Int64((attrs[.size] as? NSNumber)?.int64Value ?? 0)
        } else {
            currentFileSize = 0
        }
    }

    private func reopenFile() {
        fileHandle?.closeFile()
        guard !currentFilePath.isEmpty else { return }
        let fh = FileHandle(forWritingAtPath: currentFilePath) ?? FileHandle()
        fh.seekToEndOfFile()
        fileHandle = fh
    }

    private func rotateFile() {
        fileHandle?.closeFile()
        fileHandle = nil

        // Rotate: deepfinder.log → deepfinder.log.1 → deepfinder.log.2 → ...
        let fm = FileManager.default
        let base = currentFilePath

        // Remove oldest backup
        let oldestPath = "\(base).\(Self.maxBackupCount)"
        try? fm.removeItem(atPath: oldestPath)

        // Shift existing backups
        for i in stride(from: Self.maxBackupCount - 1, through: 1, by: -1) {
            let oldPath = "\(base).\(i)"
            let newPath = "\(base).\(i + 1)"
            try? fm.moveItem(atPath: oldPath, toPath: newPath)
        }

        // Move current to .1
        try? fm.moveItem(atPath: base, toPath: "\(base).1")

        // Open new empty file
        FileManager.default.createFile(atPath: base, contents: nil)
        let fh = FileHandle(forWritingAtPath: base) ?? FileHandle()
        fh.seekToEndOfFile()
        fileHandle = fh
        currentFileSize = 0
    }
}
