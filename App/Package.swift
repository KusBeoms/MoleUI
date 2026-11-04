// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MoleUI",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "MoleUI", path: "Sources/MoleUI", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
