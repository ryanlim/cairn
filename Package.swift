// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cairn",
    // iOS 17 + macOS 14 are the floor: SwiftData and Swift Testing
    // both require this generation. The CairnIOSCore target additionally
    // uses PhotoKit / Security / SwiftData APIs available since iOS 17.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CairnCore", targets: ["CairnCore"]),
        // iOS-side concrete implementations of CairnCore's protocols. Compiles
        // on macOS too (Keychain, SwiftData, UserDefaults are available there)
        // but PhotoKit-backed types are gated by `#if canImport(Photos)`.
        .library(name: "CairnIOSCore", targets: ["CairnIOSCore"]),
        .executable(name: "cairn", targets: ["CairnCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "CairnCore"),
        .target(
            name: "CairnIOSCore",
            dependencies: ["CairnCore"]
        ),
        .executableTarget(
            name: "CairnCLI",
            dependencies: [
                "CairnCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "CairnCoreTests",
            dependencies: ["CairnCore"]
        ),
        .testTarget(
            name: "CairnIOSCoreTests",
            dependencies: ["CairnIOSCore", "CairnCore"]
        ),
    ]
)
