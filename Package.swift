// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DBoard",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DBoard",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
