import DeepFinder
import Darwin
import Foundation

@main
struct DaemonEntry {
    static func main() async {
        let daemon = DaemonMain()

        do {
            try await daemon.run()
        } catch DaemonError.alreadyRunning(let pid) {
            FileHandle.standardError.write(
                Data("deepfinder-daemon: already running (PID \(pid))\n".utf8)
            )
            Darwin.exit(1)
        } catch {
            FileHandle.standardError.write(
                Data("deepfinder-daemon: \(error.localizedDescription)\n".utf8)
            )
            Darwin.exit(1)
        }
    }
}
