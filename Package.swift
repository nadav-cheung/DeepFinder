// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "deep-finder",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DeepFinder", targets: ["DeepFinder"]),
    ],
    targets: [
        .target(
            name: "DeepFinder",
            path: "Sources"
        ),
        .testTarget(
            name: "DeepFinderTests",
            dependencies: ["DeepFinder"],
            path: "Tests"
        ),
    ]
)
