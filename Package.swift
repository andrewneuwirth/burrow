// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Burrow",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Burrow", path: "Sources/Burrow", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
