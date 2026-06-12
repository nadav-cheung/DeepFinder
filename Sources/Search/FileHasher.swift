// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import CryptoKit
import DeepFinderIndex

/// Computes SHA-256 hashes of file contents for duplicate detection.
public struct FileHasher: Sendable {

    /// Prevent instantiation — all API is static.
    private init() {}

    /// Compute the SHA-256 hex digest of the file at the given path.
    /// Returns nil if the file cannot be opened or read.
    /// Reads in 64 KB chunks to keep memory usage bounded.
    public static func sha256(ofFileAtPath path: String) -> String? {
        // Verify file exists — InputStream(fileAtPath:) succeeds even for
        // non-existent paths, but open() sets streamError asynchronously.
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let inputStream = InputStream(fileAtPath: path) else { return nil }
        inputStream.open()
        defer { inputStream.close() }

        if inputStream.streamError != nil { return nil }

        var hasher = SHA256()
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                // Stream error
                return nil
            }
            if bytesRead == 0 {
                // EOF
                break
            }
            hasher.update(data: Data(bytesNoCopy: buffer, count: bytesRead, deallocator: .none))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
