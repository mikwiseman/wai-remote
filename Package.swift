// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WAIRemote",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "RemoteCore", targets: ["RemoteCore"]),
        .executable(name: "WAIRemote", targets: ["WAIRemote"]),
        .executable(name: "WAIRemoteWatchdog", targets: ["WAIRemoteWatchdog"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "153.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "RemoteCore"),
        .executableTarget(name: "WAIRemote", dependencies: ["RemoteCore", "WebRTC", "Sparkle"]),
        .executableTarget(name: "WAIRemoteWatchdog"),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),
        .testTarget(name: "WAIRemoteTests", dependencies: ["WAIRemote"])
    ],
    swiftLanguageModes: [.v5]
)
