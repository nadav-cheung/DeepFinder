import Foundation
import CryptoKit

// MARK: - PathEncryption Errors

/// Errors thrown by ``PathEncryption`` during encrypt/decrypt operations.
enum PathEncryptionError: Error, CustomStringConvertible {
    case keyReadFailed
    case keyWriteFailed(Error)
    case keyInvalid
    case encodingFailed
    case decodingFailed
    case encryptionFailed(Error)
    case decryptionFailed(Error)
    case invalidCiphertext

    var description: String {
        switch self {
        case .keyReadFailed:
            return "Failed to read encryption key from secrets store"
        case .keyWriteFailed(let error):
            return "Failed to write encryption key to secrets store: \(error.localizedDescription)"
        case .keyInvalid:
            return "Encryption key is invalid (not valid Base64 or wrong length)"
        case .encodingFailed:
            return "Failed to encode/decode string as UTF-8"
        case .decodingFailed:
            return "Failed to decode ciphertext from Base64"
        case .encryptionFailed(let error):
            return "Encryption failed: \(error.localizedDescription)"
        case .decryptionFailed(let error):
            return "Decryption failed: \(error.localizedDescription)"
        case .invalidCiphertext:
            return "Ciphertext is too short (must be at least 28 bytes: 12 nonce + 16 tag)"
        }
    }
}

// MARK: - PathEncryption

/// AES-256-GCM encryption for file paths stored in SQLite.
///
/// Since the system SQLite3 does not support `sqlite3_key`, paths are encrypted
/// at the application layer before writing to the database and decrypted after
/// reading. Each encryption uses a fresh 12-byte nonce, producing a unique
/// ciphertext even for identical plaintext.
///
/// ## Key Management
///
/// A random 256-bit AES key is generated on first use and stored in the secrets
/// file (`~/.deep-finder/secrets.json`) via ``SecretsStore``. The key persists
/// across daemon restarts and system reboots. If the key is lost (file deleted,
/// migration to a new Mac), the database becomes unreadable and must be rebuilt
/// via full rescan.
///
/// ## Wire Format
///
/// The encrypted output is a Base64-encoded string containing:
/// ```
/// [12 bytes nonce] + [ciphertext] + [16 bytes GCM tag]
/// ```
/// This is stored directly in the `path` and `parent_path` TEXT columns.
///
/// ## Thread Safety
///
/// All methods are synchronous and computationally cheap (AES-GCM is hardware-
/// accelerated on Apple Silicon). The struct is `Sendable`.
///
/// REQ-3.0-18: Path encryption at the persistence layer.
struct PathEncryption: Sendable {

    /// Secrets file key used to store the AES-256 key.
    private static let secretsKey = "path_encryption_key_v1"

    /// The secrets store used to persist the encryption key.
    private let secretsStore: SecretsStore

    /// Cached symmetric key, loaded once on first use.
    private let symmetricKey: SymmetricKey

    // MARK: - Init

    /// Initialize the path encryption service.
    ///
    /// Loads the encryption key from the secrets file, or generates a new one if none exists.
    ///
    /// - Parameter secretsStore: The secrets store to use. Defaults to the standard
    ///   secrets file (`~/.deep-finder/secrets.json`).
    /// - Throws: ``PathEncryptionError`` if the key cannot be loaded or created.
    init(secretsStore: SecretsStore = SecretsStore()) throws {
        self.secretsStore = secretsStore
        self.symmetricKey = try Self.loadOrCreateKey(using: secretsStore)
    }

    // MARK: - Public API

    /// Encrypt a plaintext string using AES-256-GCM.
    ///
    /// Each call produces a unique ciphertext because a fresh random nonce is used.
    ///
    /// - Parameter plaintext: The plaintext string to encrypt.
    /// - Returns: A Base64-encoded string containing nonce + ciphertext + tag.
    /// - Throws: ``PathEncryptionError`` if encryption fails.
    func encrypt(_ plaintext: String) throws -> String {
        guard let data = plaintext.data(using: .utf8) else {
            throw PathEncryptionError.encodingFailed
        }

        let nonce = AES.GCM.Nonce()
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(data, using: symmetricKey, nonce: nonce)
        } catch {
            throw PathEncryptionError.encryptionFailed(error)
        }

        // Wire format: nonce (12) + ciphertext + tag (16)
        var combined = Data(capacity: 12 + sealedBox.ciphertext.count + 16)
        combined.append(Data(nonce))
        combined.append(sealedBox.ciphertext)
        combined.append(sealedBox.tag)
        return combined.base64EncodedString()
    }

    /// Decrypt a Base64-encoded ciphertext back to plaintext.
    ///
    /// - Parameter encrypted: A Base64-encoded string in the wire format
    ///   (nonce + ciphertext + tag).
    /// - Returns: The original plaintext string.
    /// - Throws: ``PathEncryptionError`` if decryption fails or the ciphertext is malformed.
    func decrypt(_ encrypted: String) throws -> String {
        guard let combined = Data(base64Encoded: encrypted) else {
            throw PathEncryptionError.decodingFailed
        }

        // Minimum size: 12 (nonce) + 16 (tag) = 28 bytes
        guard combined.count >= 28 else {
            throw PathEncryptionError.invalidCiphertext
        }

        let nonceData = combined.prefix(12)
        let tagData = combined.suffix(16)
        let ciphertext = combined.dropFirst(12).dropLast(16)

        let nonce: AES.GCM.Nonce
        let sealedBox: AES.GCM.SealedBox
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
            sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData)
        } catch {
            throw PathEncryptionError.decryptionFailed(error)
        }

        let decryptedData: Data
        do {
            decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw PathEncryptionError.decryptionFailed(error)
        }

        guard let result = String(data: decryptedData, encoding: .utf8) else {
            throw PathEncryptionError.encodingFailed
        }
        return result
    }

    /// Returns `true` if the encrypted string is likely encrypted data
    /// (valid Base64, at least 28 decoded bytes). Does NOT verify the
    /// encryption key — only checks structural validity.
    ///
    /// Used during migration to detect whether paths are already encrypted.
    static func looksEncrypted(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value), data.count >= 28 else {
            return false
        }
        return true
    }

    // MARK: - Key Management

    /// Load the AES-256 key from the secrets file, or generate and store a new one.
    private static func loadOrCreateKey(using secretsStore: SecretsStore) throws -> SymmetricKey {
        if let stored = secretsStore.load(key: secretsKey) {
            guard let keyData = Data(base64Encoded: stored) else {
                throw PathEncryptionError.keyInvalid
            }
            guard keyData.count == 32 else {
                throw PathEncryptionError.keyInvalid
            }
            return SymmetricKey(data: keyData)
        }

        // Generate a new random 256-bit key
        let key = SymmetricKey(size: .bits256)
        let keyString = key.withUnsafeBytes { Data($0).base64EncodedString() }
        do {
            try secretsStore.save(key: secretsKey, value: keyString)
        } catch {
            throw PathEncryptionError.keyWriteFailed(error)
        }
        return key
    }
}
