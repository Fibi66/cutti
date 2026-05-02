# cutti

AI-powered video editing app for macOS **and iOS** (iPhone + iPad universal).
Import your footage, click Start — cutti's AI handles transcription, scene
analysis, and edit suggestions.


## Setup

### Prerequisites

- macOS 14+ with **Xcode 16** (Swift 6 toolchain) installed
- For iOS builds: `brew install xcodegen`

### 1. Build & run macOS

```bash
cd macos/CuttiMac
swift build
swift run
```

On first build, SwiftPM auto-downloads the vendored `sherpa-onnx` and
`onnxruntime` xcframeworks (~45 MB total) from this repo's GitHub
release into the SwiftPM cache. WhisperKit model weights (~1.5 GB) are
downloaded automatically on first **launch** into
`macos/CuttiMac/Models/` (gitignored).

### 2. Build & run iOS

```bash
cd ios/CuttiMobile
xcodegen generate           # MUST re-run after editing project.yml
open CuttiMobile.xcodeproj
```

For **Simulator** builds: works out of the box.

For **device / TestFlight / App Store** builds: open `project.yml`, set
`DEVELOPMENT_TEAM` to your own Apple Developer Team ID and change
`bundleIdPrefix` to your own reverse-DNS prefix, then re-run
`xcodegen generate`.

## Testing

```bash
# macOS app + cross-platform package (one combined run)
cd macos/CuttiMac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Shared package alone
cd shared/CuttiKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## License

[AGPL-3.0](LICENSE).
