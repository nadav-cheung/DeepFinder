import AppKit
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - UpdateChecker

/// Checks GitHub Releases for new versions of DeepFinder.
///
/// No external dependencies — pure URLSession. Auto-throttles to one check
/// per 24 hours via UserDefaults. Used by the Settings About tab to show
/// update availability and by the status bar menu.
@MainActor
@Observable
final class UpdateChecker {

    // MARK: - State

    /// Whether an update is available (newer version found on GitHub).
    private(set) var isUpdateAvailable: Bool = false

    /// The latest version tag found on GitHub (e.g. "v3.3.0").
    private(set) var latestVersion: String?

    /// Whether a check is currently in progress.
    private(set) var isChecking: Bool = false

    /// Error message if the last check failed.
    private(set) var errorMessage: String?

    /// Date of the last successful check.
    private(set) var lastCheckDate: Date?

    /// The current installed version.
    public let currentVersion: String

    // MARK: - Constants

    private static let lastCheckKey = "\(Product.identifier).lastUpdateCheck"
    private static let throttleInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    private static let releasesURL = URL(string: "https://api.github.com/repos/nadav-cheung/DeepFinder/releases/latest")!

    // MARK: - Init

    public init(currentVersion: String = Product.version) {
        self.currentVersion = currentVersion
        self.lastCheckDate = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    // MARK: - Public API

    /// Checks for updates. Throttled to once per 24 hours unless `force` is true.
    ///
    /// - Parameter force: If true, bypasses the 24-hour throttle.
    public func checkForUpdates(force: Bool = false) async {
        // Throttle check.
        if !force, let lastCheck = lastCheckDate,
           Date().timeIntervalSince(lastCheck) < Self.throttleInterval {
            return
        }

        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil

        do {
            let latest = try await fetchLatestRelease()
            latestVersion = latest.tagName
            isUpdateAvailable = isVersionNewer(latest.tagName, than: currentVersion)
            lastCheckDate = Date()
            UserDefaults.standard.set(lastCheckDate, forKey: Self.lastCheckKey)
        } catch {
            errorMessage = error.localizedDescription
        }

        isChecking = false
    }

    /// Opens the GitHub Releases page in the default browser.
    public func openReleasePage() {
        let url = URL(string: "https://github.com/nadav-cheung/DeepFinder/releases")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    /// Fetches the latest release from GitHub API.
    ///
    /// Sets the recommended `Accept` header per GitHub API docs.
    /// Handles 304 Not Modified (ETag match) by returning the cached version.
    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.httpError(-1)
        }

        // 304 means our cached version is still current.
        guard httpResponse.statusCode != 304 else {
            // If we have a cached version, return it as-is (no update).
            if let latest = latestVersion {
                return GitHubRelease(tagName: latest)
            }
            throw UpdateError.httpError(304)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw UpdateError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    /// Compares two version strings. Both may have optional "v" prefix.
    ///
    /// Returns true if `remote` is semantically newer than `local`.
    private func isVersionNewer(_ remote: String, than local: String) -> Bool {
        let cleanRemote = remote.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let cleanLocal = local.trimmingCharacters(in: CharacterSet(charactersIn: "v"))

        let remoteParts = cleanRemote.split(separator: ".").compactMap { Int($0) }
        let localParts = cleanLocal.split(separator: ".").compactMap { Int($0) }

        guard !remoteParts.isEmpty, !localParts.isEmpty else { return false }

        let maxCount = max(remoteParts.count, localParts.count)
        for i in 0..<maxCount {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false // Equal.
    }
}

// MARK: - GitHubRelease

/// Minimal model for GitHub Releases API `latest` response.
private struct GitHubRelease: Decodable {
    public let tagName: String

    public enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}

// MARK: - UpdateError

/// Errors that can occur during update checking.
private enum UpdateError: LocalizedError {
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "HTTP 错误：\(code)"
        }
    }
}
