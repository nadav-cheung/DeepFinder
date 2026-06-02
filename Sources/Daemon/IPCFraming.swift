import Foundation

// MARK: - IPCFramingIOError

/// Errors thrown by ``IPCFramingIO`` during low-level socket operations.
enum IPCFramingIOError: Error, LocalizedError {
    case writeFailed(String)
    case connectionClosed
    case readTimeout(Int)
    case messageTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let msg):
            return "Write failed: \(msg)"
        case .connectionClosed:
            return "Connection closed"
        case .readTimeout(let seconds):
            return "Read timed out after \(seconds)s"
        case .messageTooLarge(let size):
            return "Message too large: \(size) bytes"
        }
    }
}

// MARK: - IPCFramingIO

/// Socket-level I/O helpers for the IPC framing protocol.
///
/// Provides `writeAll` and `readFramedMessage` that implement the 4-byte
/// big-endian length-prefix framing used by both ``IPCClient`` and ``IPCServer``.
///
/// These are pure functions that operate on a raw file descriptor — they have
/// no actor state and can be called from any isolation context.
enum IPCFramingIO {

    /// Default maximum framed message payload size (16 MB).
    static let defaultMaxMessageSize = Constants.IPC.maxMessageSize

    // MARK: - Write

    /// Write all bytes of `data` to a file descriptor.
    ///
    /// Loops until every byte is written or an error occurs. Handles partial
    /// writes by advancing the buffer offset.
    ///
    /// - Parameters:
    ///   - fd: The file descriptor to write to.
    ///   - data: The complete data to write.
    /// - Throws: `IPCFramingIOError` if the write syscall fails or the
    ///   connection closes before all data is written.
    static func writeAll(to fd: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                throw IPCFramingIOError.writeFailed(String(cString: strerror(errno)))
            }
            if written == 0 {
                throw IPCFramingIOError.connectionClosed
            }
            offset += written
        }
    }

    // MARK: - Read

    /// Read a 4-byte-length-prefixed framed message from a file descriptor.
    ///
    /// The framing protocol: first 4 bytes are a big-endian `UInt32` declaring
    /// the payload length, followed by that many bytes of JSON payload.
    ///
    /// - Parameters:
    ///   - fd: The file descriptor to read from.
    ///   - maxMessageSize: Maximum allowed payload length. Default 16 MB.
    ///   - timeoutSeconds: Expected socket SO_RCVTIMEO in seconds, used only
    ///     for the diagnostic message in `.readTimeout`. Default 30.
    /// - Returns: The raw payload data (without the 4-byte prefix).
    /// - Throws: `IPCFramingIOError.connectionClosed` if the connection drops
    ///   mid-message, `.readTimeout` if a `read()` timed out (SO_RCVTIMEO
    ///   expiry), or `.messageTooLarge` if the declared length is excessive.
    static func readFramedMessage(
        from fd: Int32,
        maxMessageSize: Int = defaultMaxMessageSize,
        timeoutSeconds: Int = Constants.IPC.receiveTimeoutSeconds
    ) throws -> Data {
        // Read 4-byte header
        var header = Data(capacity: 4)
        while header.count < 4 {
            var buf = [UInt8](repeating: 0, count: 4 - header.count)
            let n = read(fd, &buf, buf.count)
            if n == 0 {
                throw IPCFramingIOError.connectionClosed
            }
            if n < 0 {
                if errno == EAGAIN {
                    throw IPCFramingIOError.readTimeout(timeoutSeconds)
                }
                throw IPCFramingIOError.connectionClosed
            }
            header.append(contentsOf: buf.prefix(n))
        }

        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard length > 0 else { return Data() }

        guard length <= maxMessageSize else {
            throw IPCFramingIOError.messageTooLarge(length)
        }

        // Read payload
        var payload = Data(capacity: length)
        while payload.count < length {
            let remaining = length - payload.count
            var buf = [UInt8](repeating: 0, count: min(remaining, 8192))
            let n = read(fd, &buf, buf.count)
            if n == 0 {
                throw IPCFramingIOError.connectionClosed
            }
            if n < 0 {
                if errno == EAGAIN {
                    throw IPCFramingIOError.readTimeout(timeoutSeconds)
                }
                throw IPCFramingIOError.connectionClosed
            }
            payload.append(contentsOf: buf.prefix(n))
        }

        return payload
    }
}
