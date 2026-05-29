// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "everything-search",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EverythingSearch", targets: ["EverythingSearch"]),
    ],
    targets: [
        .target(
            name: "EverythingSearch",
            path: "Sources"
        ),
        .testTarget(
            name: "EverythingSearchTests",
            dependencies: ["EverythingSearch"],
            path: "Tests"
        ),
    ]
)
