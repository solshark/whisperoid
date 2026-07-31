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
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "3.0.0"),
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
            dependencies: [
                "WhisperoidCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
    ]
)
