import Foundation
import Testing
@testable import DeepFinder

@Suite("KeychainStore")
struct KeychainStoreTests {

    @Test("Save and retrieve API key")
    func testSaveAndRetrieve() throws {
        let store = KeychainStore(service: "com.nadav.deepfinder.test")
        let key = "test-api-key-\(UUID().uuidString.prefix(8))"
        try store.save(key: key, value: "sk-test-12345")
        let retrieved = store.load(key: key)
        #expect(retrieved == "sk-test-12345")
        // Cleanup
        store.delete(key: key)
    }

    @Test("Load returns nil for missing key")
    func testLoadMissing() {
        let store = KeychainStore(service: "com.nadav.deepfinder.test")
        let key = "nonexistent-\(UUID().uuidString.prefix(8))"
        let retrieved = store.load(key: key)
        #expect(retrieved == nil)
    }

    @Test("Delete removes key")
    func testDelete() throws {
        let store = KeychainStore(service: "com.nadav.deepfinder.test")
        let key = "test-delete-\(UUID().uuidString.prefix(8))"
        try store.save(key: key, value: "sk-delete-me")
        store.delete(key: key)
        let retrieved = store.load(key: key)
        #expect(retrieved == nil)
    }

    @Test("Overwrite updates existing key")
    func testOverwrite() throws {
        let store = KeychainStore(service: "com.nadav.deepfinder.test")
        let key = "test-overwrite-\(UUID().uuidString.prefix(8))"
        try store.save(key: key, value: "old-value")
        try store.save(key: key, value: "new-value")
        let retrieved = store.load(key: key)
        #expect(retrieved == "new-value")
        store.delete(key: key)
    }

    @Test("Save and retrieve empty string")
    func testEmptyString() throws {
        let store = KeychainStore(service: "com.nadav.deepfinder.test")
        let key = "test-empty-\(UUID().uuidString.prefix(8))"
        try store.save(key: key, value: "")
        let retrieved = store.load(key: key)
        #expect(retrieved == "")
        store.delete(key: key)
    }
}
