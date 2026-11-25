// swift-tools-version: 6.0
// Swift 6 language mode (complete strict concurrency). Builds for macOS too, so `swift test` runs on the Mac.
import PackageDescription

let package = Package(
    name: "YouTubeEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "YouTubeEngine", targets: ["YouTubeEngine"]),
    ],
    targets: [
        .target(name: "YouTubeEngine"),
        .testTarget(name: "YouTubeEngineTests", dependencies: ["YouTubeEngine"]),
    ]
)
