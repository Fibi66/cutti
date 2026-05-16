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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(path: "../../shared/CuttiKit"),
    ],
    targets: [
        // Vendored sherpa-onnx static xcframework, served from the
        // public GitHub release. SwiftPM downloads + caches it on
        // first build; the checksum below pins the exact bytes.
        //
        // To roll forward: upload new zips as a new release tag,
        // recompute `swift package compute-checksum <file>.zip`,
        // and bump both the url: and checksum: here.
        .binaryTarget(
            name: "SherpaOnnxC",
            url: "https://github.com/Fibi66/cutti/releases/download/vendor-sherpa-v1.12.39-ort-1.24.4/sherpa-onnx.xcframework.zip",
            checksum: "bbceeaf8b562017eedb5303460ae2615a217f415fea8306b026fe438feb4f57a"
        ),
        // ONNX Runtime static lib that sherpa-onnx links against.
        .binaryTarget(
            name: "OnnxRuntimeC",
            url: "https://github.com/Fibi66/cutti/releases/download/vendor-sherpa-v1.12.39-ort-1.24.4/onnxruntime.xcframework.zip",
            checksum: "4ad2c3906fbaf9ed6454e796b1be80389780b9865d7ab2e379d5b37b1940555b"
        ),
        .executableTarget(
            name: "CuttiMac",
            dependencies: [
                .product(name: "CuttiKit", package: "CuttiKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                "SherpaOnnxC",
                "OnnxRuntimeC",
            ],
            path: "Sources/CuttiMac",
            resources: [
                .copy("Resources/AnimationSkill"),
                // Qwen3-ASR sidecar payload (server.py + requirements.txt
                // + VERSION). Copied verbatim — `.process` would mangle
                // the Python source. The Swift installer copies these
                // out of Bundle.module into ~/Library/Application Support
                // /cutti/qwen-asr/ on first install / on version bump.
                .copy("Resources/QwenAsrSidecar"),
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"),
                // Bundled UI fonts. Inter (UI text) + JetBrains Mono
                // (monospaced fields / IDs / version strings) are
                // registered at app launch via CTFontManager so the
                // Settings redesign can use them without depending on
                // system-installed copies. Both ship under SIL OFL 1.1
                // — license files live alongside the .otf / .ttf files
                // and are part of the bundle.
                .process("Resources/Fonts"),
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
