# cutti

AI-powered video editing app for **macOS**. Import your footage, click
Start — cutti's AI handles transcription, scene analysis, and edit
suggestions.

> **Status**
> - **macOS** — usable. Pre-built DMGs are published to
>   [Releases](https://github.com/Fibi66/cutti/releases).
> - **iOS** (iPhone + iPad) — **work in progress, not usable yet.** The
>   `ios/CuttiMobile/` target builds against the simulator so the
>   shared kit (`shared/CuttiKit/`) keeps cross-platform parity, but
>   the iOS UI is incomplete and most features are stubbed out. Don't
>   expect a working app from it. There's no TestFlight build and no
>   ETA — the macOS app is the focus right now.

## Minimum requirements (macOS)

To run the local AI features (Whisper transcription, speaker diarization,
on-device scene analysis):

- **Apple Silicon Mac** (M1 or later) — Intel / Rosetta is not supported
- **macOS 14** Sonoma or later
- **8 GB RAM** (16 GB recommended)
- **~2 GB free disk** for downloaded model weights (Whisper ~1.5 GB,
  sherpa-onnx ~47 MB)
- Internet connection on first launch to download model weights; offline
  afterwards

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

### 2. Build iOS (contributors only — UI is incomplete)

The iOS target exists so the shared kit (`shared/CuttiKit/`) doesn't
drift out of cross-platform parity. **It does not currently produce a
usable app** — most surfaces are stubs. Build it only if you're
working on `CuttiKit` and need to verify your changes still link on
iOS.

```bash
cd ios/CuttiMobile
xcodegen generate           # MUST re-run after editing project.yml
open CuttiMobile.xcodeproj
```

For **Simulator** builds: works out of the box.

For **device** builds: open `project.yml`, set `DEVELOPMENT_TEAM` to
your own Apple Developer Team ID and change `bundleIdPrefix` to your
own reverse-DNS prefix, then re-run `xcodegen generate`. There is
intentionally no TestFlight or App Store build pipeline yet.

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
