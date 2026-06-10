import Testing
import Foundation
import CryptoKit
@testable import DeepFinderPersist

@Suite("PathEncryption", .serialized)
struct PathEncryptionTests {

    // MARK: - Helpers

    /// Create a test-scoped SecretsStore backed by a temp file.
    private func makeStore() -> (SecretsStore, cleanup: () -> Void) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepfinder-test-pathenc-\(UUID().uuidString)")
        let filePath = tmpDir.appendingPathComponent("secrets.json").path
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = SecretsStore(filePath: filePath)
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: tmpDir) }
        return (store, cleanup)
    }

    /// The secrets key used by PathEncryption internally.
    private static let secretsKey = "path_encryption_key_v1"

    /// Create a PathEncryption instance using a test-scoped secrets store.
    private func makeEncryption() throws -> (PathEncryption, cleanup: () -> Void) {
        let (store, cleanup) = makeStore()
        let enc = try PathEncryption(secretsStore: store)
        return (enc, cleanup)
    }

    // MARK: - Encrypt/Decrypt Round-Trip

    @Test("encrypt then decrypt returns original plaintext")
    func roundTrip() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let plaintext = "/Users/test/Documents/readme.md"
        let encrypted = try enc.encrypt(plaintext)
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == plaintext)
    }

    @Test("each encryption produces unique ciphertext")
    func uniqueCiphertextPerCall() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let plaintext = "/same/path/file.txt"
        let c1 = try enc.encrypt(plaintext)
        let c2 = try enc.encrypt(plaintext)
        #expect(c1 != c2)
    }

    // MARK: - Empty Path

    @Test("encrypt and decrypt empty string")
    func emptyString() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let encrypted = try enc.encrypt("")
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == "")
    }

    // MARK: - Special Characters

    @Test("handles paths with spaces")
    func spacesInPath() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let plaintext = "/Users/test/My Documents/project final.txt"
        let encrypted = try enc.encrypt(plaintext)
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == plaintext)
    }

    @Test("handles paths with special shell characters")
    func specialShellChars() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let plaintext = "/Users/test/$HOME/file (copy) [2].txt"
        let encrypted = try enc.encrypt(plaintext)
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == plaintext)
    }

    @Test("handles paths with percent and hash symbols")
    func percentAndHash() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let plaintext = "/Users/test/100% progress #final.md"
        let encrypted = try enc.encrypt(plaintext)
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == plaintext)
    }

    // MARK: - Unicode Paths

    @Test("handles Chinese characters in path")
    func chinesePath() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let plaintext = "/Users/test/文档/项目报告.txt"
        let encrypted = try enc.encrypt(plaintext)
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == plaintext)
    }

    @Test("handles Japanese characters in path")
    func japanesePath() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let plaintext = "/Users/test/書類/プロジェクト.pdf"
        let encrypted = try enc.encrypt(plaintext)
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == plaintext)
    }

    @Test("handles emoji in path")
    func emojiPath() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let plaintext = "/Users/test/🎉 party 🎊/fun.txt"
        let encrypted = try enc.encrypt(plaintext)
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == plaintext)
    }

    @Test("handles Arabic RTL characters in path")
    func arabicPath() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let plaintext = "/Users/test/مستندات/ملف.txt"
        let encrypted = try enc.encrypt(plaintext)
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == plaintext)
    }

    @Test("handles decomposed Unicode (NFD) in path")
    func decomposedUnicode() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        // e + combining acute accent (NFD form of é)
        let nfdPath = "/Users/test/re\u{0301}sume\u{0301}.txt"
        let encrypted = try enc.encrypt(nfdPath)
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == nfdPath)
    }

    // MARK: - Long Paths

    @Test("handles long path (1024 characters)")
    func longPath() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let longComponent = String(repeating: "a", count: 900)
        let plaintext = "/Users/test/\(longComponent)/file.txt"
        let encrypted = try enc.encrypt(plaintext)
        let decrypted = try enc.decrypt(encrypted)
        #expect(decrypted == plaintext)
    }

    // MARK: - Corrupted / Malformed Ciphertext

    @Test("decrypting garbage Base64 throws decodingFailed")
    func garbageBase64() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        #expect(throws: PathEncryptionError.self) {
            try enc.decrypt("not-valid-base64!!!")
        }
    }

    @Test("decrypting valid Base64 that is too short throws invalidCiphertext")
    func ciphertextTooShort() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        // 16 bytes encoded as Base64 — less than the minimum 28 bytes
        let short = Data(repeating: 0xAA, count: 16).base64EncodedString()
        #expect(throws: PathEncryptionError.self) {
            try enc.decrypt(short)
        }
    }

    @Test("decrypting ciphertext with corrupted payload throws decryptionFailed")
    func corruptedPayload() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let encrypted = try enc.encrypt("/Users/test/file.txt")

        // Decode, flip a byte in the ciphertext body, re-encode
        guard var data = Data(base64Encoded: encrypted) else {
            Issue.record("Failed to decode encrypted data as Base64")
            return
        }
        // Flip a byte in the middle (between nonce and tag)
        let flipIndex = 14 // just past the 12-byte nonce
        data[flipIndex] = data[flipIndex] ^ 0xFF
        let corrupted = data.base64EncodedString()

        #expect(throws: PathEncryptionError.self) {
            try enc.decrypt(corrupted)
        }
    }

    @Test("decrypting with tampered nonce throws decryptionFailed")
    func tamperedNonce() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let encrypted = try enc.encrypt("/Users/test/file.txt")

        guard var data = Data(base64Encoded: encrypted) else {
            Issue.record("Failed to decode encrypted data as Base64")
            return
        }
        // Tamper with the nonce (first byte)
        data[0] = data[0] ^ 0xFF
        let tampered = data.base64EncodedString()

        #expect(throws: PathEncryptionError.self) {
            try enc.decrypt(tampered)
        }
    }

    @Test("decrypting with tampered GCM tag throws decryptionFailed")
    func tamperedTag() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let encrypted = try enc.encrypt("/Users/test/file.txt")

        guard var data = Data(base64Encoded: encrypted) else {
            Issue.record("Failed to decode encrypted data as Base64")
            return
        }
        // Tamper with the tag (last byte)
        let lastIdx = data.count - 1
        data[lastIdx] = data[lastIdx] ^ 0xFF
        let tampered = data.base64EncodedString()

        #expect(throws: PathEncryptionError.self) {
            try enc.decrypt(tampered)
        }
    }

    // MARK: - Wrong Key

    @Test("decrypting with a different key fails")
    func wrongKey() throws {
        let (enc1, cleanup1) = try makeEncryption()
        defer { cleanup1() }

        let encrypted = try enc1.encrypt("/Users/test/secret.txt")

        // Create a second instance with a fresh secrets store (different file = different key)
        let (enc2, cleanup2) = try makeEncryption()
        defer { cleanup2() }

        #expect(throws: PathEncryptionError.self) {
            try enc2.decrypt(encrypted)
        }
    }

    // MARK: - Wire Format

    @Test("encrypted output is valid Base64")
    func outputIsBase64() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let encrypted = try enc.encrypt("/Users/test/file.txt")
        let decoded = Data(base64Encoded: encrypted)
        #expect(decoded != nil)
    }

    @Test("encrypted output decoded length is at least 28 bytes (nonce + tag)")
    func outputMinLength() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        // Empty string encrypts to nonce(12) + ciphertext(0) + tag(16) = 28 bytes
        let encrypted = try enc.encrypt("")
        guard let decoded = Data(base64Encoded: encrypted) else {
            Issue.record("Failed to Base64-decode encrypted output")
            return
        }
        #expect(decoded.count >= 28)
    }

    @Test("encrypted non-empty path is longer than 28 bytes")
    func nonEmptyOutputLength() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let encrypted = try enc.encrypt("/Users/test/file.txt")
        guard let decoded = Data(base64Encoded: encrypted) else {
            Issue.record("Failed to Base64-decode encrypted output")
            return
        }
        // nonce(12) + ciphertext(>0) + tag(16) > 28
        #expect(decoded.count > 28)
    }

    // MARK: - looksEncrypted

    @Test("looksEncrypted returns true for valid encrypted data")
    func looksEncryptedTrue() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let encrypted = try enc.encrypt("/Users/test/file.txt")
        #expect(PathEncryption.looksEncrypted(encrypted) == true)
    }

    @Test("looksEncrypted returns false for plaintext path")
    func looksEncryptedFalseForPlaintext() {
        #expect(PathEncryption.looksEncrypted("/Users/test/file.txt") == false)
    }

    @Test("looksEncrypted returns false for short Base64")
    func looksEncryptedFalseForShortBase64() {
        // 16 bytes Base64 — less than 28 bytes when decoded
        let short = Data(repeating: 0x00, count: 16).base64EncodedString()
        #expect(PathEncryption.looksEncrypted(short) == false)
    }

    @Test("looksEncrypted returns false for empty string")
    func looksEncryptedFalseForEmpty() {
        #expect(PathEncryption.looksEncrypted("") == false)
    }

    @Test("looksEncrypted returns false for invalid Base64")
    func looksEncryptedFalseForInvalidBase64() {
        #expect(PathEncryption.looksEncrypted("!!!not-base64!!!") == false)
    }

    // MARK: - Key Management

    @Test("reusing same secrets store returns same key (idempotent init)")
    func sameKeyOnReuse() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        let enc1 = try PathEncryption(secretsStore: store)
        let enc2 = try PathEncryption(secretsStore: store)

        // If both instances use the same key, enc1-encrypted data can be
        // decrypted by enc2.
        let encrypted = try enc1.encrypt("/Users/test/file.txt")
        let decrypted = try enc2.decrypt(encrypted)
        #expect(decrypted == "/Users/test/file.txt")
    }

    @Test("key persisting across instances: first encrypt, second decrypt")
    func keyPersistsAcrossInstances() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        let enc1 = try PathEncryption(secretsStore: store)
        let encrypted = try enc1.encrypt("/Users/test/persistent.txt")

        // New instance loading the same persisted key
        let enc2 = try PathEncryption(secretsStore: store)
        let decrypted = try enc2.decrypt(encrypted)
        #expect(decrypted == "/Users/test/persistent.txt")
    }

    // MARK: - Error Descriptions

    @Test("all PathEncryptionError cases have non-empty descriptions")
    func errorDescriptions() {
        let errors: [PathEncryptionError] = [
            .keyReadFailed,
            .keyWriteFailed(NSError(domain: "test", code: -1)),
            .keyInvalid,
            .encodingFailed,
            .decodingFailed,
            .encryptionFailed(NSError(domain: "test", code: -1)),
            .decryptionFailed(NSError(domain: "test", code: -1)),
            .invalidCiphertext,
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }

    @Test("error descriptions contain useful context")
    func errorDescriptionContent() {
        #expect(PathEncryptionError.keyReadFailed.description.contains("secrets"))
        #expect(PathEncryptionError.invalidCiphertext.description.contains("28"))
        #expect(PathEncryptionError.keyInvalid.description.contains("Base64"))
        #expect(PathEncryptionError.decodingFailed.description.contains("Base64"))
    }

    // MARK: - Multiple Distinct Paths

    @Test("encrypting and decrypting multiple distinct paths")
    func multiplePaths() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let paths = [
            "/Users/test/a.txt",
            "/Users/test/b.md",
            "/Users/test/c.swift",
            "/Users/test/d.pdf",
            "/Users/test/e.jpg",
        ]

        for path in paths {
            let encrypted = try enc.encrypt(path)
            let decrypted = try enc.decrypt(encrypted)
            #expect(decrypted == path)
        }
    }

    @Test("decrypting all encrypted paths in batch succeeds")
    func batchRoundTrip() throws {
        let (enc, cleanup) = try makeEncryption()
        defer { cleanup() }

        let paths = [
            "/Users/test/docs/report.pdf",
            "/Users/test/src/main.swift",
            "/Users/test/Assets/logo.png",
        ]

        let encrypted = try paths.map { try enc.encrypt($0) }
        let decrypted = try encrypted.map { try enc.decrypt($0) }
        #expect(decrypted == paths)
    }
}
