// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Duolink",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DuolinkCore"),
        .executableTarget(name: "Duolink", dependencies: ["DuolinkCore"]),
        .executableTarget(name: "duolinkctl", dependencies: ["DuolinkCore"]),
        .testTarget(name: "DuolinkCoreTests", dependencies: ["DuolinkCore"]),
    ]
)
