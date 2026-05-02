// swift-tools-version: 6.0
import PackageDescription

// Cross-platform core for Cutti. Pure Swift / Foundation / CoreGraphics /
// AVFoundation only — NO AppKit, NO UIKit. Imported by both the macOS app
// (macos/CuttiMac) and the iOS app (ios/CuttiMobile).
let package = Package(
    name: "CuttiKit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "CuttiKit", targets: ["CuttiKit"]),
    ],
    targets: [
        .target(
            name: "CuttiKit",
            path: "Sources/CuttiKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "CuttiKitTests",
            dependencies: ["CuttiKit"],
            path: "Tests/CuttiKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
