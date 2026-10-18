// swift-tools-version: 6.0
import PackageDescription

// Note: no unsafeFlags here on purpose. Packages that use unsafeFlags cannot be
// consumed as remote dependencies, and we want bounds-checked release builds:
// "reliability" is one of the three goals, so we do not trade safety for speed.
let package = Package(
    name: "EgWalker",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "EgWalker", targets: ["EgWalker"]),
        .executable(name: "egwalker-bench", targets: ["EgWalkerBench"]),
    ],
    targets: [
        .target(name: "EgWalker"),
        .executableTarget(name: "EgWalkerBench", dependencies: ["EgWalker"]),
        .testTarget(
            name: "EgWalkerTests",
            dependencies: ["EgWalker"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
