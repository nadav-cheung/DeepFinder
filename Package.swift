// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "deep-finder",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DeepFinder", targets: ["DeepFinder"]),
        .executable(name: "deepfinder", targets: ["DeepFinderCLI"]),
        .executable(name: "deepfinder-daemon", targets: ["DeepFinderDaemon"]),
    ],
    targets: [
        .target(
            name: "DeepFinder",
            path: "Sources",
            exclude: ["CLIEntry", "DaemonEntry"],
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
        .testTarget(
            name: "DeepFinderTests",
            dependencies: ["DeepFinder"],
            path: "Tests"
        ),
    ]
)
