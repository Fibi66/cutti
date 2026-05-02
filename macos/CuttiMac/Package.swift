// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CuttiMac",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CuttiMac", targets: ["CuttiMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.12.0"),
        .package(path: "../../shared/CuttiKit"),
    ],
    targets: [
        // Vendored sherpa-onnx static xcframework. Installed by
        // scripts/setup-sherpa.sh (run once after clone; gitignored).
        .binaryTarget(
            name: "SherpaOnnxC",
            path: "Vendor/sherpa-onnx.xcframework"
        ),
        // ONNX Runtime static lib that sherpa-onnx links against.
        // Also gitignored; same setup script installs it.
        .binaryTarget(
            name: "OnnxRuntimeC",
            path: "Vendor/onnxruntime.xcframework"
        ),
        .executableTarget(
            name: "CuttiMac",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "CuttiKit", package: "CuttiKit"),
                "SherpaOnnxC",
                "OnnxRuntimeC",
            ],
            path: "Sources/CuttiMac",
            resources: [
                .copy("Resources/AnimationSkill"),
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Foundation"),
            ]
        ),
        .testTarget(
            name: "CuttiMacTests",
            dependencies: ["CuttiMac"],
            path: "Tests/CuttiMacTests",
            resources: [.process("Fixtures")]
        ),
    ]
)
