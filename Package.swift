// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "callscribe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.15.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CallScribeCore"),
        .target(
            name: "CSpeexDSP",
            cSettings: [
                .define("FLOATING_POINT"),
                .define("USE_KISS_FFT"),
                .define("EXPORT", to: ""),
            ]
        ),
        .target(
            name: "CallScribeEngine",
            dependencies: [
                "CallScribeCore",
                "CSpeexDSP",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "callscribe",
            dependencies: [
                "CallScribeCore",
                "CallScribeEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "CallScribeCoreTests",
            dependencies: ["CallScribeCore"]
        ),
        .testTarget(
            name: "CallScribeEngineTests",
            dependencies: ["CallScribeEngine", "CallScribeCore"]
        ),
    ]
)
