// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapClip",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SnapClip", targets: ["SnapClip"]),
    ],
    targets: [
        .target(name: "SnapClipCore"),
        .executableTarget(name: "SnapClip", dependencies: ["SnapClipCore"]),
        .testTarget(name: "SnapClipCoreTests", dependencies: ["SnapClipCore"]),
    ]
)
