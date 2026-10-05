// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskBuddy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DiskBuddy", path: "Sources/DiskBuddy")
    ]
)
