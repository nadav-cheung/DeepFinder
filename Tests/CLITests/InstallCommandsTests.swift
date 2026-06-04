import Testing
import Foundation
@testable import DeepFinder

@Suite("InstallCommandRunner")
struct InstallCommandsTests {

    // MARK: - Helpers

    /// Creates a temporary directory for test plist files.
    private func makeTempDir() -> String {
        let tempDir = NSTemporaryDirectory()
            + "InstallCommandsTests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true
        )
        return tempDir
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - 1. install creates plist file

    @Test("install creates plist file at specified path")
    func testInstallCreatesPlist() throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        let plistPath = tempDir + "/cn.com.nadav.deepfinder.daemon.plist"

        let exitCode = try InstallCommandRunner.install(plistPath: plistPath)
        #expect(exitCode == 0)

        // Verify file exists
        #expect(FileManager.default.fileExists(atPath: plistPath))

        // Verify it's valid XML plist
        let content = try String(contentsOfFile: plistPath, encoding: .utf8)
        #expect(content.contains("<?xml version=\"1.0\""))
        #expect(content.contains("<plist version=\"1.0\">"))
    }

    // MARK: - 2. install when already installed shows message

    @Test("install when already installed shows message and returns non-zero")
    func testInstallAlreadyInstalled() throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        let plistPath = tempDir + "/cn.com.nadav.deepfinder.daemon.plist"

        // Create a dummy file to simulate existing install
        try "dummy".write(toFile: plistPath, atomically: true, encoding: .utf8)

        let output = CapturingOutput()
        let exitCode = try InstallCommandRunner.install(
            plistPath: plistPath,
            output: output
        )

        #expect(exitCode != 0)
        #expect(output.collected.contains("Already installed"))
    }

    // MARK: - 3. uninstall removes plist file

    @Test("uninstall removes plist file")
    func testUninstallRemovesPlist() throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        let plistPath = tempDir + "/cn.com.nadav.deepfinder.daemon.plist"

        // Create a plist file first
        try LaunchAgent.installPlist(at: plistPath)
        #expect(FileManager.default.fileExists(atPath: plistPath))

        let exitCode = try InstallCommandRunner.uninstall(plistPath: plistPath)
        #expect(exitCode == 0)

        // Verify file is gone
        #expect(!FileManager.default.fileExists(atPath: plistPath))
    }

    // MARK: - 4. uninstall when not installed shows message

    @Test("uninstall when not installed shows message and returns non-zero")
    func testUninstallNotInstalled() throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        let plistPath = tempDir + "/cn.com.nadav.deepfinder.daemon.plist"

        // Don't create the file — simulate "not installed"
        let output = CapturingOutput()
        let exitCode = try InstallCommandRunner.uninstall(
            plistPath: plistPath,
            output: output
        )

        #expect(exitCode != 0)
        #expect(output.collected.contains("Not installed"))
    }

    // MARK: - 5. plist has correct Label and ProgramArguments

    @Test("plist has correct Label and ProgramArguments")
    func testPlistContent() throws {
        let tempDir = makeTempDir()
        defer { cleanup(tempDir) }

        let plistPath = tempDir + "/cn.com.nadav.deepfinder.daemon.plist"

        _ = try InstallCommandRunner.install(plistPath: plistPath)

        let content = try String(contentsOfFile: plistPath, encoding: .utf8)

        // Verify Label matches LaunchAgent.label
        let expectedLabel = LaunchAgent.label
        #expect(content.contains("<string>\(expectedLabel)</string>"))

        // Verify ProgramArguments contains the daemon binary path
        #expect(content.contains("deepfinder-daemon"))
    }
}
