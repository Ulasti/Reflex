// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReflexCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "ReflexCore", targets: ["ReflexCore"]),
        .executable(name: "reflex-cli", targets: ["ReflexCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "ReflexCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/ReflexCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ReflexCLI",
            dependencies: ["ReflexCore"],
            path: "Sources/ReflexCLI"
        )
    ]
)
