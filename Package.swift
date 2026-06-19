// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "deep-finder",
    platforms: [.macOS(.v26)],
    products: [
        // Libraries (for potential reuse by other packages)
        .library(name: "DeepFinderIndex", targets: ["DeepFinderIndex"]),
        .library(name: "DeepFinderPersist", targets: ["DeepFinderPersist"]),
        .library(name: "DeepFinderMedia", targets: ["DeepFinderMedia"]),
        .library(name: "DeepFinderSearch", targets: ["DeepFinderSearch"]),
        .library(name: "DeepFinderFS", targets: ["DeepFinderFS"]),
        .library(name: "DeepFinderAI", targets: ["DeepFinderAI"]),
        .library(name: "DeepFinderDaemon", targets: ["DeepFinderDaemon"]),
        .library(name: "DeepFinderCLI", targets: ["DeepFinderCLILib"]),
        .library(name: "DeepFinderGUI", targets: ["DeepFinderGUILib"]),
        .library(name: "DeepFinderServices", targets: ["DeepFinderServices"]),
        // Executables
        .executable(name: "deepfinder", targets: ["DeepFinderCLI"]),
        .executable(name: "deepfinder-daemon", targets: ["DeepFinderDaemonExec"]),
        .executable(name: "deepfinder-app", targets: ["DeepFinderAppExec"]),
    ],
    targets: [
        // MARK: - Leaf modules (no internal dependencies)

        .target(
            name: "CIndex",
            path: "Sources/CIndex",
            sources: ["CIndex.c", "CFileScanner.c", "CParallelScanner.c", "CTrigramIndex.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "DeepFinderIndex",
            dependencies: ["CIndex"],
            path: "Sources/Index"
        ),
        .target(
            name: "DeepFinderPersist",
            dependencies: [.target(name: "DeepFinderIndex")],
            path: "Sources/Persist"
        ),
        .target(
            name: "DeepFinderMedia",
            dependencies: [.target(name: "DeepFinderIndex")],
            path: "Sources/Media"
        ),

        // MARK: - Mid-layer modules

        .target(
            name: "DeepFinderSearch",
            dependencies: [.target(name: "DeepFinderIndex")],
            path: "Sources/Search"
        ),
        .target(
            name: "DeepFinderFS",
            dependencies: [.target(name: "DeepFinderIndex"), .target(name: "DeepFinderPersist")],
            path: "Sources/FS"
        ),
        .target(
            name: "DeepFinderAI",
            dependencies: [
                .target(name: "DeepFinderIndex"),
                .target(name: "DeepFinderSearch"),
                .target(name: "DeepFinderPersist"),
            ],
            path: "Sources/AI",
            resources: [.process("Prompts")]
        ),

        // MARK: - Top-layer modules

        .target(
            name: "DeepFinderDaemon",
            dependencies: [
                .target(name: "DeepFinderIndex"),
                .target(name: "DeepFinderSearch"),
                .target(name: "DeepFinderFS"),
                .target(name: "DeepFinderPersist"),
            ],
            path: "Sources/Daemon"
        ),
        .target(
            name: "DeepFinderCLILib",
            dependencies: [
                .target(name: "DeepFinderIndex"),
                .target(name: "DeepFinderSearch"),
                .target(name: "DeepFinderDaemon"),
                .target(name: "DeepFinderAI"),
                .target(name: "DeepFinderServices"),
            ],
            path: "Sources/CLI",
            linkerSettings: [.linkedLibrary("edit")]
        ),
        .target(
            name: "DeepFinderGUILib",
            dependencies: [
                .target(name: "DeepFinderIndex"),
                .target(name: "DeepFinderSearch"),
                .target(name: "DeepFinderDaemon"),
                .target(name: "DeepFinderAI"),
                .target(name: "DeepFinderFS"),
                .target(name: "DeepFinderMedia"),
                .target(name: "DeepFinderCLILib"),
                .target(name: "DeepFinderServices"),
            ],
            path: "Sources/GUI"
        ),
        .target(
            name: "DeepFinderServices",
            dependencies: [
                .target(name: "DeepFinderIndex"),
                .target(name: "DeepFinderDaemon"),
            ],
            path: "Sources/Services"
        ),

        // MARK: - Executable entry points (thin wrappers)

        .executableTarget(
            name: "DeepFinderCLI",
            dependencies: [.target(name: "DeepFinderCLILib")],
            path: "Sources/CLIEntry"
        ),
        .executableTarget(
            name: "DeepFinderDaemonExec",
            dependencies: [.target(name: "DeepFinderDaemon")],
            path: "Sources/DaemonEntry"
        ),
        .executableTarget(
            name: "DeepFinderAppExec",
            dependencies: [.target(name: "DeepFinderGUILib")],
            path: "Sources/AppEntry"
        ),

        // MARK: - Test targets (per-module)

        .testTarget(
            name: "DeepFinderIndexTests",
            dependencies: [.target(name: "DeepFinderIndex")],
            path: "Tests/IndexTests"
        ),
        .testTarget(
            name: "DeepFinderPersistTests",
            dependencies: [.target(name: "DeepFinderPersist"), .target(name: "DeepFinderIndex")],
            path: "Tests/PersistTests"
        ),
        .testTarget(
            name: "DeepFinderMediaTests",
            dependencies: [.target(name: "DeepFinderMedia"), .target(name: "DeepFinderIndex"), .target(name: "DeepFinderSearch")],
            path: "Tests/MediaTests"
        ),
        .testTarget(
            name: "DeepFinderSearchTests",
            dependencies: [.target(name: "DeepFinderSearch"), .target(name: "DeepFinderIndex"), .target(name: "DeepFinderAI"), .target(name: "DeepFinderPersist")],
            path: "Tests/SearchTests"
        ),
        .testTarget(
            name: "DeepFinderFSTests",
            dependencies: [.target(name: "DeepFinderFS"), .target(name: "DeepFinderIndex"), .target(name: "DeepFinderPersist"), .target(name: "DeepFinderSearch")],
            path: "Tests/FSTests"
        ),
        .testTarget(
            name: "DeepFinderAITests",
            dependencies: [.target(name: "DeepFinderAI"), .target(name: "DeepFinderSearch"), .target(name: "DeepFinderPersist")],
            path: "Tests/AITests"
        ),
        .testTarget(
            name: "DeepFinderDaemonTests",
            dependencies: [.target(name: "DeepFinderDaemon"), .target(name: "DeepFinderIndex"), .target(name: "DeepFinderSearch"), .target(name: "DeepFinderFS"), .target(name: "DeepFinderPersist")],
            path: "Tests/DaemonTests"
        ),
        .testTarget(
            name: "DeepFinderCLITests",
            dependencies: [.target(name: "DeepFinderCLILib"), .target(name: "DeepFinderIndex"), .target(name: "DeepFinderSearch"), .target(name: "DeepFinderDaemon"), .target(name: "DeepFinderAI"), .target(name: "DeepFinderFS"), .target(name: "DeepFinderPersist"), .target(name: "DeepFinderServices")],
            path: "Tests/CLITests"
        ),
        .testTarget(
            name: "DeepFinderGUITests",
            dependencies: [.target(name: "DeepFinderGUILib"), .target(name: "DeepFinderIndex"), .target(name: "DeepFinderSearch"), .target(name: "DeepFinderDaemon"), .target(name: "DeepFinderAI"), .target(name: "DeepFinderFS"), .target(name: "DeepFinderPersist"), .target(name: "DeepFinderCLILib"), .target(name: "DeepFinderServices")],
            path: "Tests/GUITests"
        ),
        .testTarget(
            name: "DeepFinderServicesTests",
            dependencies: [.target(name: "DeepFinderServices"), .target(name: "DeepFinderIndex"), .target(name: "DeepFinderDaemon"), .target(name: "DeepFinderSearch"), .target(name: "DeepFinderAI"), .target(name: "DeepFinderFS"), .target(name: "DeepFinderPersist"), .target(name: "DeepFinderCLILib")],
            path: "Tests/ServicesTests"
        ),
    ]
)
