# Cutti iOS

Universal iOS app (iPhone + iPad) scaffold for Cutti. Target iOS 17+, Swift 6 / SwiftUI.

## Generate the Xcode project

Project files are generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen), so we don't commit the `.xcodeproj` binary blob.

```bash
brew install xcodegen
cd ios/CuttiMobile
xcodegen generate
open CuttiMobile.xcodeproj
```

## Layout strategy

One target, Universal App. `RootView` dispatches by `horizontalSizeClass`:

- **compact** (iPhone portrait, iPhone non-Max landscape, iPad Slide Over) → `EditorPhoneLayout`
  - Jianying-style: preview on top, tool strip in the middle, multi-track timeline on the bottom.
- **regular** (iPad, iPad Split View full/half, iPhone Pro Max landscape) → `EditorPadLayout`
  - `NavigationSplitView`: media sidebar · preview+timeline · inspector.

Business logic (Core/Media) will be shared from a future `CuttiKit` Swift package extracted out of `macos/CuttiMac`.

## Status

Scaffold only. Real features not yet wired:
- [ ] Share `CuttiKit` package with the macOS target
- [ ] `AVPlayerLayer`-backed preview
- [ ] Thumbnail-rendered timeline + pinch/pan/trim gestures
- [ ] `PHPickerViewController` import
- [ ] AI pipeline integration
- [ ] Export via `AVAssetExportSession`
