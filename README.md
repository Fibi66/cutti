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

To run the local AI features (Qwen3-ASR transcription, speaker
diarization, on-device scene analysis):

- **Apple Silicon Mac** (M1 or later) — Intel / Rosetta is not supported
- **macOS 14** Sonoma or later
- **16 GB RAM** recommended (Qwen3-ASR runs on the Apple Silicon GPU
  via MPS; 8 GB works but leaves little headroom alongside the editor)
- **~8 GB free disk** for the local ASR sidecar: a private Python
  runtime + venv (~2 GB, torch / transformers / etc.), the
  `Qwen/Qwen3-ASR-1.7B` weights (~3.5 GB), the
  `Qwen/Qwen3-ForcedAligner-0.6B` weights (~1.2 GB), plus the
  sherpa-onnx diarization model (~47 MB)
- Internet connection on first launch to download the sidecar and
  model weights; offline afterwards. If the sidecar isn't installed
  (e.g. you skipped the prompt), cutti falls back to Apple's built-in
  `SFSpeech` recognizer for transcription.

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
release into the SwiftPM cache. The Qwen3-ASR sidecar (private Python
runtime + model weights, ~7 GB) is **not** fetched at build time —
it's installed on demand from the in-app prompt the first time you
transcribe, into `~/Library/Application Support/cutti/qwen-asr/`
(runtime + venv) and `~/Library/Caches/cutti/qwen-asr/huggingface/`
(model weights). Both directories are removed when you uninstall
the sidecar from Settings.

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

## Known issues / future improvements

These are known limitations that we intend to fix in future releases.
None of them block normal use — they just mean some workflows are
rougher than they should be:

- **One-click first cut can't be paused or resumed.** Once the
  pipeline starts (transcribe → scene analysis → audio quality → LLM
  edit), the only way to stop it is to quit the app or wait it out.
  Re-opening the project re-runs the analysis from scratch instead of
  picking up where it left off.
- **No mid-flight cancel for transcription.** A long clip (e.g. a
  24-minute lecture) can take 10–15 minutes to transcribe locally with
  Qwen3-ASR. Closing the analysis chat panel doesn't actually cancel
  the in-flight request; the sidecar keeps working until it finishes.
- **No background / "headless" analysis.** Closing the app stops the
  local sidecar, which means transcribing a long clip requires
  keeping the app in the foreground for the full duration.
- **No per-segment re-analysis.** If a single clip's auto-cut comes
  out wrong, you have to re-run the analysis on the whole project,
  not just that clip.
- **Limited language coverage for the local model.** Qwen3-ASR
  currently ships with Chinese, Cantonese, and English aligners.
  Other languages fall back to Apple Speech and won't get per-word
  timing.

If you hit something else that feels broken or missing, please open
an issue at <https://github.com/Fibi66/cutti/issues>.

## License

[AGPL-3.0](LICENSE).
