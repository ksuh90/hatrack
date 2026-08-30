// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hatrack",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Hatrack",
            path: "Sources/Hatrack",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
