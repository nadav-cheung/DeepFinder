import AppKit
import DeepFinder

@main
struct DeepFinderAppEntry {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let config = DeepFinderAppConfiguration.production()
        app.delegate = DeepFinderAppDelegate(configuration: config)
        app.run()
    }
}
