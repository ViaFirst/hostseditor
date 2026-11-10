// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HostsEditor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HostsEditor", path: "Sources/HostsEditor")
    ]
)
