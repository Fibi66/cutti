# CuttiKit Boundaries

CuttiKit is the Swift package shared by **CuttiMac** (AppKit + macOS) and
**CuttiMobile** (SwiftUI + iPhone/iPad). This document defines what belongs in
the kit and what does not. **Read this before adding or moving a file.**

## Mental model

> CuttiKit is the *contract* between the two apps — the data they both
> agree on and the rules they both obey. Everything else is
> platform-specific and stays in each app's folder.

Changing a file in CuttiKit affects **both** platforms. This is intentional
for schema/rule code (you WANT drift prevention) but painful for UI or
platform-API wrappers (you DON'T want cross-platform QA for a macOS-only
tweak). The rules below keep the painful stuff out.

## What belongs in CuttiKit

A file may live in CuttiKit **only if** it satisfies all three:

1. **Both apps need it, or will need it within the next feature cycle.** No
   speculative "might be useful" migrations. Rule of thumb: there must be
   (or be about to be) a call site on both sides.
2. **It depends only on Foundation + Apple frameworks available on both
   iOS 17+ and macOS 14+** (AVFoundation, CoreGraphics, CoreImage,
   Accelerate, Combine, Swift stdlib). No AppKit. No UIKit. No SwiftUI
   views. No `#if os(macOS)` branches.
3. **It has no UI state and no editor/session ownership.** Pure data types,
   pure algorithms, actors that own files on disk — OK. View models,
   `@Published` editor state, undo stacks, toolbar commands — NOT OK.

If any one fails, the file belongs in `macos/CuttiMac/` or
`ios/CuttiMobile/`.

## What does NOT belong — even if it looks reusable

- SwiftUI views, `@StateObject`/`@EnvironmentObject` owners, view models
- Anything importing `AppKit`, `UIKit`, or `SwiftUI`
- Editor undo stacks / selection / multi-selection state
- Menu commands, toolbar items, keyboard shortcuts
- File pickers, drag-and-drop session handling
- Player instances, preview playback coordination (the AVPlayer lives in
  the app's document object)
- OS-specific integrations: Photos/PHPicker (iOS), QuickLook (macOS),
  StoreKit UI, share sheets
- Code that we haven't yet needed on both sides. "Predictive sharing" is
  banned.

## Current contents (2026-05-05)

### Data & persistence — `Project/`
The project file format. Both apps must read/write the same JSON on disk.

- `Project`, `ProjectInfo`, `ProjectRegistry`, `ProjectStore` — project
  directory layout
- `MediaManifest`, `MediaAssetRecord` — imported-media catalog
- `EditorSessionState` — session.json payload (tracks, subtitle style,
  autosave timestamp)
- `EditorRevision`, `RevisionStore` — undo-history file format
- `AICopilotMetadata` (`TimelineSegment`, `TimeRange`, `Track`, effects,
  `PiPLayout`, `FreeTransform`) — timeline data model
- `SubtitleStyle`, `SubtitleStylePatch`, `SubtitleTombstone` — subtitle
  schema
- `BRollSuggestion`, `OverlayRenderSpec`, `PiPSuggestion` — AI suggestion
  payloads stored with the project
- `TranscriptTypes` — transcript data format

### Pure rules / algorithms — `Media/`
Platform-free math and planning. No I/O, no AVFoundation mutation.

- `MultiTrackComposer` — multi-track placement planner
- `PiPGeometry` — PiP layout geometry
- `ProxyPrewarmPlan`, `ProxyProfile` — proxy encoding config
- `VoiceEnhancer` — offline AVAudioEngine processor. Pure Apple APIs
  available on both platforms; `VoiceEnhancer.Settings` is part of the
  project schema so it has to live alongside `Project`.

### AI action system — `Core/`
See the "AI platform capability" section below for the per-action split.

- `AIAction`, `AIActionBatch`, `AIActionExecutor` — LLM-emitted edit ops
  and their executor against `[TimelineSegment]`
- `AIActionValidator` — preflight validator (safe ranges, no overlapping
  subtitle edits, etc.)
- `CreativeAction` — higher-level "AI creative" operations (title cards,
  B-roll, Ken Burns, crossfades) as data
- `ProposedBatch` — Copilot proposal wrapper

What **does NOT** live here (stays macOS-only, by design):

- `OpenAIClient`, `ToolDefinition`, LLM streaming glue
  → requires relay-backed networking that we route through the cloud
  worker. When iOS grows its own relay entry point, the
  `OpenAIConfiguration` layer will move to the kit; the `OpenAIClient`
  body itself probably stays shared via a cross-platform network layer.
- `AIActionSystem`'s `ToolDefinition` extension half (the tool-schema
  generator) — currently in `macos/.../Core/AIActionSystem.swift`, not
  in the kit, because it depends on `ToolDefinition` above.
- `CreativeAction`'s tool-schema extension half — same reason, lives in
  `macos/.../Core/CreativeAction.swift`.
- Remotion rendering / Azure cloud compositor — macOS-specific pipeline.

## AI platform capability matrix

Every AI action (`AIAction` + `CreativeAction` case) is categorised as
**Both**, **macOS-only**, or **iOS-only**. "Both" means both apps' executors
understand and can apply it; "platform-only" means the other app's executor
must reject it (validator returns an error) and the LLM tool schema on that
platform must not offer it.

Today **all `AIAction` cases are Both** — they only mutate
`[TimelineSegment]` / `SubtitleEntry`, which is schema every platform owns.
This includes `insertSourceClip`, which slices an arbitrary source media
record into the timeline (powering cold-open hook teasers and callbacks)
— it produces a regular `TimelineSegment` whose source range references
a foreign `MediaAssetRecord`, so iOS executors can apply it once they
gain a media library and an LLM driver.

`CreativeAction`:

| Case | Status | Reason |
| --- | --- | --- |
| `insertBRoll` | Both | Pure timeline manipulation (adds overlay segment). |
| `applyKenBurns` | Both | Pan+zoom via AVComposition; both platforms render. |
| `insertCrossfade` | Both | Dissolve via AVComposition; both platforms render. |
| `insertTitleCard` | macOS-only (for now) | Currently rendered through Remotion. iOS gets a native Core Animation / AVComposition variant later; when it lands, upgrade to Both. |

Rule: when you add a new action case, classify it in this table in the
same PR.

### Executor design principle

- `AIActionExecutor` in CuttiKit executes the **Both** subset.
  Platform-only cases are surfaced as a typed error
  (`.unsupportedOnThisPlatform`) that the app's higher-level executor
  intercepts. (Not yet implemented; to be added when iOS gets its first
  LLM path — see TODO below.)
- Platform-specific side effects (Remotion render, custom
  AVVideoCompositing, StoreKit-triggered cloud render) run in each app's
  own layer *after* the kit's executor has mutated the timeline.

## How to promote a file INTO CuttiKit

1. Verify the three entry criteria above.
2. `git mv` the file, `public`-ise its declarations (enums / structs /
   classes / top-level funcs), add explicit `public init(...)` for
   memberwise-init callers across the module boundary.
3. Add `Sendable` conformance where the type crosses actor boundaries
   (most model types should be `Sendable`).
4. Remove `import AppKit` / `import UIKit` / `import SwiftUI`.
5. Run **all three** builds green:
   ```
   cd shared/CuttiKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && swift test
   cd macos/CuttiMac  && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && swift test
   cd ios/CuttiMobile    && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project CuttiMobile.xcodeproj -scheme CuttiMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO
   ```
6. Commit atomically — the move and the publicisation together.

## How to DEMOTE a file out of CuttiKit

If a kit file is only ever called from macOS and the iOS "need" evaporated:

1. Check with `grep -rn TypeName ios/CuttiMobile/Sources` that no iOS code
   references it.
2. `git mv` it to `macos/CuttiMac/Sources/CuttiMac/...`.
3. Drop redundant `public` qualifiers (same target doesn't need them).
4. Remove corresponding tests from `CuttiKitTests`; recreate in
   `CuttiMacTests` if coverage is lost.
5. Re-run all three builds.

## Anti-patterns seen before (don't repeat)

- **"It might be useful on iOS one day"** — banned. Wait until the call
  site exists. Moving is cheap (`git mv`); living with bi-platform risk
  is expensive.
- **Splitting a type** (half in the kit, half in the app) is fine
  *only* when the split reflects a genuine capability boundary, e.g.
  action data in the kit + LLM tool-schema generator in the app because
  `ToolDefinition` lives in `OpenAIClient`. Don't split for convenience.
- **Re-implementing shared logic** on one side "to avoid touching the
  kit" defeats the point. If you catch yourself doing this, either move
  the logic into the kit (drift prevention) or accept that it's
  platform-specific and own that.

## TODO

- Add typed platform-unsupported error to `AIActionExecutor` when iOS
  gets its first LLM path. Until then, iOS does not call the executor
  at all, so the question is theoretical.
- When iOS grows a relay-backed OpenAI client, evaluate moving
  `OpenAIConfiguration` and the transport layer into the kit.
