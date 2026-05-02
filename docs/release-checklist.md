# Release checklist — going PUBLIC

This repo is currently **PRIVATE**. A handful of things have to be flipped
before flipping `Settings → General → Change visibility → Public`.

## Before flipping the switch

### 1. Switch SwiftPM binary targets to remote URL mode

`macos/CuttiMac/Package.swift` currently uses `path: "Vendor/..."` so
local builds work without a public release URL. The remote URLs +
checksums are already kept in comments next to each `binaryTarget`.

```swift
// from
.binaryTarget(name: "SherpaOnnxC",  path: "Vendor/sherpa-onnx.xcframework")
.binaryTarget(name: "OnnxRuntimeC", path: "Vendor/onnxruntime.xcframework")

// to
.binaryTarget(
    name: "SherpaOnnxC",
    url: "https://github.com/Fibi66/cutti/releases/download/vendor-sherpa-v1.12.39-ort-1.24.4/sherpa-onnx.xcframework.zip",
    checksum: "bbceeaf8b562017eedb5303460ae2615a217f415fea8306b026fe438feb4f57a"
)
.binaryTarget(
    name: "OnnxRuntimeC",
    url: "https://github.com/Fibi66/cutti/releases/download/vendor-sherpa-v1.12.39-ort-1.24.4/onnxruntime.xcframework.zip",
    checksum: "4ad2c3906fbaf9ed6454e796b1be80389780b9865d7ab2e379d5b37b1940555b"
)
```

The release at
`https://github.com/Fibi66/cutti/releases/tag/vendor-sherpa-v1.12.39-ort-1.24.4`
is already created with both assets uploaded.

### 2. Stop tracking the local Vendor/ workaround

In `.gitignore`, remove these four lines:

```
# Vendored xcframeworks (private-repo mode). When the repo goes public,
# Package.swift switches to remote `url:` binaryTargets and these lines
# can be removed.
macos/CuttiMac/Vendor/sherpa-onnx.xcframework/
macos/CuttiMac/Vendor/onnxruntime.xcframework/
```

Then locally `rm -rf macos/CuttiMac/Vendor/` so the working tree is
clean. SwiftPM will re-fetch the binaries from the release URLs into
its global cache on the next build.

### 3. Verify a clean build picks up the public release

```bash
cd macos/CuttiMac
rm -rf .build
swift build
```

Expected: SwiftPM logs `Downloading binary artifact …` for both
xcframeworks, build succeeds. If you see `404`, the repo isn't actually
public yet — release assets follow repo visibility.

### 4. Sanity-sweep the README + docs

Open `README.md` and confirm it doesn't reference any private-only
flow (it shouldn't — the public flow is just `swift build && swift
run`).

### 5. Delete this file

```bash
git rm docs/release-checklist.md
```

It's only here as a reminder; it has no value once the switch is done.

## After flipping the switch

- Watch the [Releases page](https://github.com/Fibi66/cutti/releases) —
  the `vendor-sherpa-…` assets should now be downloadable anonymously.
- Try a fresh `git clone` in `/tmp` and run `swift build` to confirm
  the open-source experience works end-to-end.
- Update the local-machine `git remote` URL if you'd like (no change
  needed if the repo name stays the same).

## Things that stay the same

- `https://api.cutti.app` relay base URL — public DNS, no harm.
- Bundle ID `app.cutti.*` — your namespace; forks must change theirs.
- `DEVELOPMENT_TEAM` is already empty; forks fill in their own.
- LICENSE (AGPL-3.0) — no change.
