import Testing
import Foundation
@testable import DeepFinderDaemon

struct ConfigStoreTests {

    // MARK: - Helpers

    /// Create a unique temp directory for each test. Caller must defer removal.
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Full path for a config file inside the temp dir.
    private func configPath(in dir: URL) -> String {
        dir.appendingPathComponent("config.json").path
    }

    // MARK: - 1. Default config when no file exists

    @Test func getReturnsDefaultConfigWhenFileDoesNotExist() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configPath: configPath(in: dir))
        let config = await store.get()

        #expect(config.excludedPaths == ["/System", "/Library"])
        #expect(config.indexBatchSize == 100)
        #expect(config.maxResults == 1000)
        #expect(config.configVersion == 1)
    }

    // MARK: - 2. Round-trip: set then get persists across instances

    @Test func roundTripPersistsAcrossInstances() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = configPath(in: dir)

        // Write via first instance
        let store1 = ConfigStore(configPath: path)
        try await store1.set(key: "indexBatchSize", value: "500")
        try await store1.set(key: "maxResults", value: "5000")

        // Read via second instance
        let store2 = ConfigStore(configPath: path)
        let config = await store2.get()
        #expect(config.indexBatchSize == 500)
        #expect(config.maxResults == 5000)
    }

    // MARK: - 3. get(key:) returns individual values

    @Test func getByKeyReturnsCorrectValue() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configPath: configPath(in: dir))
        let val = await store.get(key: "indexBatchSize")
        #expect(val == "100")
    }

    @Test func getByKeyReturnsNilForUnknownKey() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configPath: configPath(in: dir))
        let val = await store.get(key: "nonexistent")
        #expect(val == nil)
    }

    // MARK: - 4. Set individual key

    @Test func setUpdatesSingleKey() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configPath: configPath(in: dir))
        try await store.set(key: "excludedPaths", value: "[\"/System\",\"/private\"]")

        let config = await store.get()
        #expect(config.excludedPaths == ["/System", "/private"])
        // Other fields unchanged
        #expect(config.indexBatchSize == 100)
        #expect(config.maxResults == 1000)
    }

    // MARK: - 5. Batch update via transform

    @Test func updateTransformsConfigAtomically() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configPath: configPath(in: dir))
        try await store.update { config in
            var mut = config
            mut.indexBatchSize = 200
            mut.maxResults = 2000
            mut.excludedPaths.append("/private")
            return mut
        }

        let config = await store.get()
        #expect(config.indexBatchSize == 200)
        #expect(config.maxResults == 2000)
        #expect(config.excludedPaths == ["/System", "/Library", "/private"])
    }

    // MARK: - 6. Atomic write verified (no partial file)

    @Test func atomicWriteProducesValidJSON() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = configPath(in: dir)

        let store = ConfigStore(configPath: path)
        try await store.set(key: "maxResults", value: "42")

        // File should be valid JSON
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode(DaemonConfig.self, from: data)
        #expect(decoded.maxResults == 42)
    }

    // MARK: - 7. File permissions 600

    @Test func filePermissionsAre600() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = configPath(in: dir)

        let store = ConfigStore(configPath: path)
        try await store.set(key: "maxResults", value: "100")

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600, "Config file should have 600 permissions")
    }

    // MARK: - 8. Corrupted file falls back to defaults

    @Test func corruptedFileFallsBackToDefaults() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = configPath(in: dir)

        // Write garbage
        try "NOT VALID JSON {{{".write(toFile: path, atomically: true, encoding: .utf8)

        let store = ConfigStore(configPath: path)
        let config = await store.get()
        // Should fall back to defaults
        #expect(config.excludedPaths == ["/System", "/Library"])
        #expect(config.indexBatchSize == 100)
        #expect(config.maxResults == 1000)
    }

    // MARK: - 9. Update throws on invalid transform result

    @Test func setThrowsOnInvalidExcludedPathsJSON() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configPath: configPath(in: dir))
        await #expect(throws: (any Error).self) {
            try await store.set(key: "excludedPaths", value: "not a json array")
        }
    }

    // MARK: - 10. ConfigStore re-reads after write

    @Test func inMemoryCacheReflectsWrite() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(configPath: configPath(in: dir))

        // Default
        let before = await store.get()
        #expect(before.indexBatchSize == 100)

        // After set, same instance should reflect
        try await store.set(key: "indexBatchSize", value: "999")
        let after = await store.get()
        #expect(after.indexBatchSize == 999)
    }
}
