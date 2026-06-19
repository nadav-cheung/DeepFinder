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

        #expect(config.excludedPaths == ["/System", "/Library", "/tmp", "/private/tmp"])
        #expect(config.indexBatchSize == 100)
        #expect(config.maxResults == 1000)
        #expect(config.configVersion == 3)
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
        #expect(config.excludedPaths == ["/System", "/Library", "/tmp", "/private/tmp", "/private"])
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
        #expect(config.excludedPaths == ["/System", "/Library", "/tmp", "/private/tmp"])
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

    // MARK: - 11. Atomic publish leaves no orphaned temp files after overwrites

    @Test func persistLeavesNoTempFilesAfterOverwrite() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = configPath(in: dir)

        let store = ConfigStore(configPath: path)
        // Three overwrites of an existing file exercise the replaceItem publish path.
        try await store.set(key: "indexBatchSize", value: "200")
        try await store.set(key: "maxResults", value: "3000")
        try await store.set(key: "indexBatchSize", value: "400")

        // Only the config file may remain — no orphaned .tmp.* files from the publish step.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let leftovers = entries.filter { $0.contains(".tmp") }
        #expect(leftovers.isEmpty, "Orphaned temp files left by persist(): \(leftovers)")
        #expect(entries.filter { !$0.contains(".tmp") } == ["config.json"])

        // Final value must reflect the last write (replaceItem preserved data integrity).
        let store2 = ConfigStore(configPath: path)
        let config = await store2.get()
        #expect(config.indexBatchSize == 400)
        #expect(config.maxResults == 3000)
    }

    // MARK: - Sort preference persistence (REQ-1.3-04)

    @Test func sortPreferenceRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = configPath(in: dir)

        let store1 = ConfigStore(configPath: path)
        try await store1.set(key: "sort", value: "date")
        try await store1.set(key: "sortReverse", value: "true")

        let store2 = ConfigStore(configPath: path)
        #expect(await store2.get(key: "sort") == "date")
        #expect(await store2.get(key: "sortReverse") == "true")
    }

    @Test func sortPreferenceClearsWhenEmpty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(configPath: configPath(in: dir))

        try await store.set(key: "sort", value: "date")
        try await store.set(key: "sort", value: "")  // empty clears

        #expect(await store.get(key: "sort") == "")
        let config = await store.get()
        #expect(config.sortPreference == nil)
    }

    @Test func sortPreferenceRejectsInvalidCriterion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(configPath: configPath(in: dir))

        do {
            try await store.set(key: "sort", value: "bogus")
            Issue.record("Expected invalidValue error")
        } catch let error as ConfigStoreError {
            if case .invalidValue(let key, _) = error {
                #expect(key == "sort")
            } else {
                Issue.record("Unexpected ConfigStoreError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func configWithoutSortFieldsLoadsForwardCompat() async throws {
        // A settings.json written before sort fields existed must still decode.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = configPath(in: dir)

        let oldJSON = """
            {"excludedPaths":[],"excludedVolumes":[],"indexBatchSize":100,"maxResults":1000,"configVersion":1}
            """
        try oldJSON.write(toFile: path, atomically: true, encoding: .utf8)

        let store = ConfigStore(configPath: path)
        let config = await store.get()
        #expect(config.indexBatchSize == 100)
        #expect(config.sortPreference == nil)
        #expect(config.sortReverse == nil)
    }
}
