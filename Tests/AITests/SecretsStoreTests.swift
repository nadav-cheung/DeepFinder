import Foundation
import Testing
@testable import DeepFinder

@Suite("SecretsStore")
struct SecretsStoreTests {

    // MARK: - Helpers

    /// Create a test-scoped SecretsStore backed by a temp file.
    /// The temp file is cleaned up after each test.
    private func makeStore() -> (SecretsStore, cleanup: () -> Void) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepfinder-test-secrets-\(UUID().uuidString)")
        let filePath = tmpDir.appendingPathComponent("secrets.json").path

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let store = SecretsStore(filePath: filePath)
        let cleanup: () -> Void = {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        return (store, cleanup)
    }

    // MARK: - Save and Load

    @Test("Save and retrieve a value")
    func testSaveAndRetrieve() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try store.save(key: "test-key", value: "sk-test-12345")
        let retrieved = store.load(key: "test-key")
        #expect(retrieved == "sk-test-12345")
    }

    @Test("Load returns nil for missing key")
    func testLoadMissing() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        let retrieved = store.load(key: "nonexistent")
        #expect(retrieved == nil)
    }

    @Test("Load returns nil when file does not exist")
    func testLoadNoFile() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        // File was never written
        #expect(store.load(key: "any") == nil)
    }

    // MARK: - Delete

    @Test("Delete removes key")
    func testDelete() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try store.save(key: "to-delete", value: "sk-delete-me")
        let deleted = store.delete(key: "to-delete")
        #expect(deleted == true)
        #expect(store.load(key: "to-delete") == nil)
    }

    @Test("Delete returns false for missing key")
    func testDeleteMissing() {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        let deleted = store.delete(key: "nonexistent")
        #expect(deleted == false)
    }

    // MARK: - Overwrite

    @Test("Overwrite updates existing key")
    func testOverwrite() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try store.save(key: "test-key", value: "old-value")
        try store.save(key: "test-key", value: "new-value")
        let retrieved = store.load(key: "test-key")
        #expect(retrieved == "new-value")
    }

    // MARK: - Edge Cases

    @Test("Save and retrieve empty string")
    func testEmptyString() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try store.save(key: "empty", value: "")
        let retrieved = store.load(key: "empty")
        #expect(retrieved == "")
    }

    @Test("Multiple keys coexist")
    func testMultipleKeys() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try store.save(key: "key-a", value: "value-a")
        try store.save(key: "key-b", value: "value-b")
        try store.save(key: "key-c", value: "value-c")

        #expect(store.load(key: "key-a") == "value-a")
        #expect(store.load(key: "key-b") == "value-b")
        #expect(store.load(key: "key-c") == "value-c")
    }

    @Test("Deleting one key does not affect others")
    func testDeleteIsolation() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try store.save(key: "keep", value: "keep-value")
        try store.save(key: "remove", value: "remove-value")
        store.delete(key: "remove")

        #expect(store.load(key: "keep") == "keep-value")
        #expect(store.load(key: "remove") == nil)
    }

    // MARK: - File Properties

    @Test("Created file has 600 permissions")
    func testFilePermissions() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        try store.save(key: "perm-test", value: "value")

        let attrs = try FileManager.default.attributesOfItem(atPath: store.filePath)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("File persists across store instances")
    func testPersistenceAcrossInstances() throws {
        let (store1, cleanup) = makeStore()
        defer { cleanup() }

        try store1.save(key: "persistent", value: "survives-restart")

        // Create a new store pointing at the same file
        let store2 = SecretsStore(filePath: store1.filePath)
        #expect(store2.load(key: "persistent") == "survives-restart")
    }

    @Test("Handles corrupted file gracefully")
    func testCorruptedFile() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }

        // Write garbage to the file
        let dir = (store.filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("not valid json!!!".utf8).write(to: URL(fileURLWithPath: store.filePath))

        // Should not crash, return nil for all keys
        #expect(store.load(key: "any") == nil)

        // Should be able to save new values (recovers)
        try store.save(key: "after-corruption", value: "works")
        #expect(store.load(key: "after-corruption") == "works")
    }

    // MARK: - Tilde Expansion

    @Test("Default init uses Product.secretsPath")
    func testDefaultInit() {
        let store = SecretsStore()
        // Path should be expanded from ~
        #expect(store.filePath.contains(".deep-finder"))
        #expect(store.filePath.contains(".env"))
        // Should NOT start with ~
        #expect(!store.filePath.hasPrefix("~"))
    }
}
