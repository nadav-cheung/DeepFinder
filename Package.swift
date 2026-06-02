// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "deep-finder",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DeepFinder", targets: ["DeepFinder"]),
        .executable(name: "deepfinder", targets: ["DeepFinderCLI"]),
        .executable(name: "deepfinder-daemon", targets: ["DeepFinderDaemon"]),
        .executable(name: "deepfinder-app", targets: ["DeepFinderApp"]),
    ],
    targets: [
        .target(
            name: "DeepFinder",
            path: "Sources",
            exclude: ["CLIEntry", "DaemonEntry", "AppEntry"],
            resources: [
                .process("AI/Prompts")
            ],
            linkerSettings: [
                .linkedLibrary("edit")
            ]
        ),
        .executableTarget(
            name: "DeepFinderCLI",
            dependencies: ["DeepFinder"],
            path: "Sources/CLIEntry"
        ),
        .executableTarget(
            name: "DeepFinderDaemon",
            dependencies: ["DeepFinder"],
            path: "Sources/DaemonEntry"
        ),
        .executableTarget(
            name: "DeepFinderApp",
            dependencies: ["DeepFinder"],
            path: "Sources/AppEntry"
        ),
        .testTarget(
            name: "DeepFinderTests",
            dependencies: ["DeepFinder"],
            path: "Tests"
        ),
    ]
)
