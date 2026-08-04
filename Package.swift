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
        // On-device text cleanup. MLX rather than a local server: the server
        // approach worked but required the user to install and run Ollama
        // separately, which is not something an app can rely on.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4"),
    ],
    targets: [
        .target(
            name: "WhisperoidCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
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
        // Development tool: scores the embedded cleanup model against the
        // spike's ground truth. Must be built with xcodebuild, since SwiftPM on
        // the command line cannot compile MLX's Metal shaders.
        .executableTarget(
            name: "cleanupcheck",
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
