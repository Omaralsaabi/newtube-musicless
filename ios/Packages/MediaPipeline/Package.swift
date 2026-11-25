// swift-tools-version: 6.0
// Swift 6 language mode (complete strict concurrency). Builds for macOS too, so `swift test` runs on the Mac.
import PackageDescription

let package = Package(
    name: "MediaPipeline",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MediaPipeline", targets: ["MediaPipeline"]),
    ],
    targets: [
        .target(name: "MediaPipeline"),
        .testTarget(name: "MediaPipelineTests", dependencies: ["MediaPipeline"]),
    ]
)
