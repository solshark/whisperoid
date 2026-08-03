// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whisperoid",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Whisperoid", targets: ["Whisperoid"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
    ],
    targets: [
        .target(
            name: "WhisperoidCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .executableTarget(
            name: "Whisperoid",
            dependencies: ["WhisperoidCore"]
        ),
        // Development tool: replays a recording through the real
        // SilenceDetector to tune auto-stop against actual speech.
        .executableTarget(
            name: "vadcheck",
            dependencies: ["WhisperoidCore"]
        ),
        // Runs as a gate in scripts/package.sh: a release is not built from
        // code that does not pass these.
        .testTarget(
            name: "WhisperoidCoreTests",
            dependencies: ["WhisperoidCore"]
        ),
    ]
)
