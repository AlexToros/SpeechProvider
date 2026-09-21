// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpeechProvider",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpeechProvider", targets: ["SpeechProvider"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "SpeechProvider",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/SpeechProvider",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SpeechProviderTests",
            dependencies: ["SpeechProvider"],
            path: "Tests/SpeechProviderTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
