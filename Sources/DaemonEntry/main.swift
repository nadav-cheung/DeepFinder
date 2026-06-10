import Darwin

import Foundation

import DeepFinderDaemon



@main

struct DaemonEntry {

    static func main() async {

        let daemon = DaemonMain()



        do {

            try await daemon.run()

        } catch DaemonError.alreadyRunning(let pid) {

            FileHandle.standardError.write(

                // String must match Product.daemonCommand (not accessible across module boundaries).

                Data("deepfinder-daemon: already running (PID \(pid))\n".utf8)

            )

            Darwin.exit(1)

        } catch {

            FileHandle.standardError.write(

                // String must match Product.daemonCommand (not accessible across module boundaries).

                Data("deepfinder-daemon: \(error.localizedDescription)\n".utf8)

            )

            Darwin.exit(1)

        }

    }

}
