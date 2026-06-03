import AppKit
import DeepFinder

// DeepFinder GUI entry point.
//
// LSUIElement menu bar app: no Dock icon, no Cmd+Tab entry. Activation policy
// is set to `.accessory` here and `NSApplicationSupportsAutomaticTermination`
// is set to `false` in `App/Info.plist` so macOS never auto-kills the app for
// being idle. That Info.plist key is the only mechanism needed to keep the
// app alive — no swizzling, signal handlers, or repeating timers required.
//
// stderr is redirected to ~/.deep-finder/logs/gui-<timestamp>.log so that
// Swift runtime warnings, OSLog prints to stderr, and any fputs-based
// diagnostics from AppKit are preserved for post-crash diagnosis. Without
// this, LSUIElement apps have nowhere to write crash-side information.
//
// See `docs/superpowers/specs/reqs/v2.0-gui.md` REQ-2.0-09, REQ-2.0-14, REQ-2.0-15.

@main
struct DeepFinderAppEntry {
    nonisolated(unsafe) static var retainedDelegate: DeepFinderAppDelegate?

    static func main() {
        redirectStderrToLogFile()
        fputs("[\(timestamp())] DeepFinderApp starting\n", stderr)

        // Ignore SIGPIPE globally. Writing to a closed socket (e.g., daemon
        // disconnected between searches) must return EPIPE, not kill the process.
        signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let config = DeepFinderAppConfiguration.production()
        let delegate = DeepFinderAppDelegate(configuration: config)
        retainedDelegate = delegate
        app.delegate = delegate

        fputs("[\(timestamp())] Calling app.run()\n", stderr)
        fflush(stderr)
        app.run()
    }

    /// Redirect stderr to a per-launch log file under ~/.deep-finder/logs/.
    ///
    /// LSUIElement apps have no attached terminal, so without this any fputs
    /// to stderr (including Swift runtime warnings) is lost.
    private static func redirectStderrToLogFile() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".deep-finder/logs")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logPath = logDir.appendingPathComponent("gui-\(Int(Date().timeIntervalSince1970)).log").path
        if let logFile = freopen(logPath, "a", stderr) {
            setvbuf(logFile, nil, _IONBF, 0)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
