# MediaCoreViewModel @Published Audit (Phase-2 prep)

Date: 2026-04-21
Scope: read-only audit of `macos/CuttiMac/Sources/CuttiMac/UI/MediaCoreViewModel.swift` (7433 lines, 42 `@Published` properties).

Goal: give Phase 2 a concrete decomposition target so one hot property (e.g. `exportProgress` during render, or rapid `bannerMessage` toggles) does not force SwiftUI to re-evaluate every subscriber of the ViewModel.

---

## How the ViewModel is consumed today

The ViewModel is held by exactly two views:

- `ContentView` — `@StateObject private var viewModel: MediaCoreViewModel`. Reads ~80 distinct properties/methods and passes them into child views as plain values or `Binding`s. This is the big subscriber: any `@Published` mutation re-evaluates `ContentView.body`.
- `EditorSessionContainer` — `@ObservedObject var viewModel: MediaCoreViewModel`. Only reads `isAnalyzing`, `isExporting`, `isImporting`, `canExport` for the toolbar chrome.

The editor subviews (`TimelineDock`, `ViewerStage`, `ChatPanel`, `TranscriptView`, `ImageGenerationSheet`, `PiPOverlayHandle`) do NOT observe the ViewModel directly — all data arrives as struct parameters or `Binding`s constructed inside `ContentView.body`. This means:

1. The invalidation fan-out bottleneck is `ContentView.body`, not the subviews themselves.
2. SwiftUI will diff each subview's input struct and skip work when inputs are equal — but the body closure still runs, and any non-trivial construction (e.g. the `overlayRows`, `detachedAudioRows`, `markers`, `brollOptions` arrays assembled inline in `ContentView.body`) runs every time.
3. Sub-ObservableObjects only help if a subview observes them directly. Otherwise the refactor must also move the corresponding `viewModel.X` reads out of `ContentView.body` and into a child that observes the sub-store.

This shapes the recommendation at the bottom.

---

## 1. All @Published properties, grouped by change cadence

### (A) Per-frame / playback-hot (fires at sub-second cadence)

None. `playheadSeconds` is `@State private` on `ContentView`, not a ViewModel field, so the 60 Hz playhead timer does NOT go through `@Published`. The ViewModel avoids per-frame fan-out today. (This is good — do not regress.)

Close-to-hot but not strictly per-frame:
| Field | Line | Cadence | Notes |
|---|---|---|---|
| `exportProgress` | 58 | ~10 Hz during export | Only while `isExporting`; progress bar + cancel button. |
| `analysisProgress` | 54 | ~1–5 Hz during analysis | Only while `isAnalyzing`; analysis sheet. |


### (B) Per-user-action (click / drag / keystroke cadence)

| Field | Line | Trigger | Notes |
|---|---|---|---|
| `player` | 24 | Composition rebuild / record switch | Has `didSet` to pause outgoing player. |
| `selectedRecordID` | 53 | Click in media list |  |
| `selectedSegmentID` | 119 | Click in timeline |  |
| `selectedSegmentIDs` | 121 | Click / shift-click / select-all |  |
| `selectedOverlaySegmentID` | 126 | Click on overlay pill |  |
| `selectedSubtitleID` | 152 | Click on subtitle pill |  |
| `isSubtitleSelected` | 146 | Click subtitle box in viewer |  |
| `editingSubtitleCueID` | 162 | Enter subtitle inline edit |  |
| `subtitleStyle` | 139 | Style slider / color picker drag | `willSet` pushes undo stack. |
| `subtitlesPreviewHidden` | 134 | Gutter eye toggle |  |
| `showSubtitles` | 128 | Menu toggle |  |
| `playbackRate` | 207 | 1x/2x button |  |
| `inPoint` / `outPoint` | 209 / 211 | `I` / `O` keys |  |
| `isLooping` | 213 | Loop toggle |  |
| `agentMode` | 90 | Chat header toggle |  |
| `chatAttachments` | 96 | Drag segment onto composer |  |
| `inspectorOverlaySegmentID` | 709 | Double-click overlay pill |  |
| `project` | 108 | Every edit (trim, split, delete, overlay move, etc.) | **Large; mutated very often.** |

### (C) Async / intermittent (seconds-to-minutes cadence)

| Field | Line | Trigger |
|---|---|---|
| `records` | 52 | Import complete / analysis complete / delete |
| `importingFiles` | 63 | Import start / finish |
| `isImporting` | 60 | Import start / finish |
| `isAnalyzing` | 55 | Analysis start / finish |
| `isExporting` | 56 | Export start / finish |
| `isCancellingExport` | 57 | User hits Cancel during export |
| `isChatProcessing` | 82 | LLM request start / finish |
| `chatMessages` | 81 | Each LLM turn, each user send |
| `pendingProposals` | 86 | LLM emits a batch (manual mode) |
| `composedSubtitles` | 154 | Composition rebuild |
| `speakers` | 166 | Diarization complete / manual add |
| `autosaveStatus` | 178 | 30 s timer + debounced save |
| `revisions` | 220 | Any revision-worthy edit |
| `overlaysRendering` | 703 | Remotion render start / finish |
| `autoPiPStatus` | 3076 | Auto-PiP analyzer lifecycle |
| `pipSuggestions` | 3108 | Background scanner finishes |
| `isGeneratingChapters` | 3569 | Chapter AI start / finish |
| `visualMarkers` | 3846 | `refreshVisualMarkers` result |
| `isLoadingVisualMarkers` | 3847 | `refreshVisualMarkers` lifecycle |
| `bannerMessage` | 51 | Ad-hoc user-facing banner |

### (D) Derived / snapshot (rare)

Nothing strictly here — the VM uses computed properties (`selectedRecord`, `canExport`, `currentChapters`, `currentChapterBarStyle`, `freeTransformTarget`, `pendingDeletionIDs`, `pendingSpeedChangeIDs`, `pendingVolumeChangeIDs`, etc.) that read from the `@Published` fields above. These recompute every time `ContentView.body` re-evaluates.

---

## 2. Per-view consumption

`TimelineDock`, `ViewerStage`, `ChatPanel`, `TranscriptView` do NOT observe the ViewModel — they receive data as parameters from `ContentView`. The table below therefore lists which VM fields each view's branch of `ContentView.body` reads (i.e. which fields invalidate that subtree when they change).

### TimelineDock

Reads (via ContentView → TimelineDock props):
- `records`, `selectedRecordID`, `projectRoot`
- `timelineSegments` (computed from `project`), `player`
- `selectedSegmentIDs`, `selectedSegmentID`, `selectedOverlaySegmentID` (Binding)
- `showSubtitles` (Binding), `subtitleStyle` (Binding)
- `composedSubtitles`, `selectedSubtitleID`, `speakers`
- `project.overlayTracks`, `project.audioTracks` (for overlay/detached-audio rows)
- `project.tracks` (track kind / muted / locked flags)
- `subtitlesPreviewHidden`
- `overlaysRendering`
- `visualMarkers`, `isLoadingVisualMarkers`
- `pendingDeletionIDs`, `pendingSpeedChangeIDs`, `pendingVolumeChangeIDs` (computed)

### ViewerStage

Reads:
- `player`, `selectedRecord`, `selectedRecordMessage`
- `playbackRate` (Binding), `isLooping` (Binding)
- `showSubtitles`, `subtitlesPreviewHidden`
- `subtitleStyle` (Binding), `isSubtitleSelected` (Binding)
- `currentChapters`, `currentChapterBarStyle` (both computed from `project`+`records`)
- `selectedSegmentIDs`, `selectedOverlaySegmentID`
- `project.overlayTracks` (PiP overlays; geometry + layout)
- `composedSubtitles` / `speakers` (via `currentSubtitleText(at:)` at playheadSeconds)

### ChatPanel

Reads:
- `chatMessages`, `isChatProcessing`, `agentMode`
- `pendingProposals`
- `chatAttachments`, `records`, `projectRoot`, `timelineSegments` (for attachment chips)
- `isAnalyzing` (AI analysis button disabled state)

### TranscriptView (lower-half tab)

Reads:
- `composedSubtitles`, `speakers`, `player`
- (also receives playheadSeconds from ContentView `@State`)

### Media list / ProjectDashboard / top toolbar

Reads:
- `records`, `selectedRecordID`, `importingFiles`, `projectRoot`
- `isImporting`, `isAnalyzing`, `analysisProgress`, `isExporting`, `exportProgress`, `isCancellingExport`
- `autosaveStatus`, `bannerMessage`, `pipSuggestions`
- `revisions` (history panel)

### Agent trace / free transform / overlay inspector

Reads:
- `freeTransformTarget` (computed), `inspectorOverlaySegmentID`
- `selectedOverlaySegmentID`, `overlaysRendering`, `isSubtitleSelected`

---

## 3. Recommendation — 4 sub-ObservableObjects

The rule of thumb: co-locate properties that (a) change together, (b) are read by the same subtree, and (c) are missed when absent by views outside that subtree. Anything else is a false group.

Because today nothing outside `ContentView` directly observes the VM, the first win is **shrinking ContentView.body** — passing sub-stores into leaf views as `@ObservedObject` so mutation of one store does not re-evaluate siblings. The proposed 4 stores:

### 3.1 `EditorPlaybackStore` (per-action, playback-related)

Move: `player`, `playbackRate`, `inPoint`, `outPoint`, `isLooping`, `showSubtitles`, `subtitlesPreviewHidden`, `subtitleStyle`, `isSubtitleSelected`, `editingSubtitleCueID`.

Subscribers: `ViewerStage`, the in-viewer subtitle overlay.
Payoff: a style-slider scrub no longer invalidates the timeline chrome or the media list.
Risk: `subtitleStyle`'s `willSet` undo push must keep working — migrate the undo stack owner together.

### 3.2 `EditorSelectionStore` (timeline selection state)

Move: `selectedSegmentID`, `selectedSegmentIDs`, `selectedOverlaySegmentID`, `selectedSubtitleID`, `selectedRecordID`, `inspectorOverlaySegmentID`.

Subscribers: `TimelineDock`, `ViewerStage` (for free-transform + PiP handles), the inspector column, the media list selection highlight.
Payoff: clicking a segment no longer dirties the ChatPanel / export toolbar / analysis sheet subtrees.
Risk: shift-click anchor (`selectionAnchorSegmentID`) and `handleSegmentClick` must move with these fields.

### 3.3 `EditorChatStore` (AI chat + proposals)

Move: `chatMessages`, `isChatProcessing`, `pendingProposals`, `agentMode`, `chatAttachments`.

Subscribers: `ChatPanel` and the pending-proposal banner.
Payoff: during an LLM stream (fast `chatMessages` append cadence — especially delta streaming if/when adopted), the timeline + viewer subtrees do not re-evaluate.
Risk: Attachments need `records` for the chip thumbnails; pass them as a separate param rather than absorbing `records` into this store (records mutate on a different cadence).

### 3.4 `EditorPipelineStatusStore` (long-running / async status)

Move: `isImporting`, `importingFiles`, `isAnalyzing`, `analysisProgress`, `isExporting`, `exportProgress`, `isCancellingExport`, `autosaveStatus`, `autoPiPStatus`, `pipSuggestions`, `isGeneratingChapters`, `isLoadingVisualMarkers`, `overlaysRendering`, `bannerMessage`.

Subscribers: top toolbar, status footer, media list overlays, PiP suggestion banner.
Payoff: the 10 Hz `exportProgress` stream during render no longer re-evaluates `ContentView.body` — only the toolbar/progress sheet subtree re-renders.
Risk: `overlaysRendering` is read by `TimelineDock` (spinner on overlay pill). Either pass that single field through or let TimelineDock observe the pipeline store.

### Left on the root ViewModel

- `project` (too central and too many writers to split in Phase 2; the bigger win here is making `project` itself Equatable or moving tracks onto a separate store per track kind)
- `records`, `composedSubtitles`, `speakers`, `revisions`, `visualMarkers` — these are the canonical content and every pane reads them; splitting them further does not reduce fan-out.

### Sequencing for Phase 2

1. Start with `EditorPipelineStatusStore` — lowest-risk (status fields are mostly write-by-VM, read-by-toolbar) and highest payoff during export.
2. Then `EditorChatStore` — self-contained, ChatPanel is already a leaf.
3. Then `EditorSelectionStore` — most mechanical changes because selection fields are touched in many handlers; do it last among the three easy wins.
4. `EditorPlaybackStore` only after an `.equatable(by:)` boundary is placed around `ViewerStage`, since `subtitleStyle` is a struct and scrubbing must stay jitter-free on the viewer alone.

Only after (1)–(3) does the ContentView.body closure actually shrink to the point where the root-VM `project` mutations stop being a bottleneck.
