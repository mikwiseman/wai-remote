// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WAIRemote",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "RemoteCore", targets: ["RemoteCore"]),
        .executable(name: "WAIRemote", targets: ["WAIRemote"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "153.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "RemoteCore"),
        .executableTarget(name: "WAIRemote", dependencies: ["RemoteCore", "WebRTC", "Sparkle"]),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"])
    ],
    swiftLanguageModes: [.v5]
)
