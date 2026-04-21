// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cairn",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CairnCore", targets: ["CairnCore"]),
        .executable(name: "cairn", targets: ["CairnCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "CairnCore"),
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
    ]
)
