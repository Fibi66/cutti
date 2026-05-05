import AVFoundation
import CoreImage
import CuttiKit

/// Export resolution options.
enum ExportResolution: String, CaseIterable, Identifiable {
    case original = "Original"
    case hd1080 = "1080p"
    case hd720 = "720p"
    case sd480 = "480p"

    var id: String { rawValue }

    /// Returns the target height, or nil for original resolution.
    var targetHeight: Int? {
        switch self {
        case .original: return nil
        case .hd1080: return 1080
        case .hd720: return 720
        case .sd480: return 480
        }
    }
}

/// Describes a composed segment's position in the final timeline.
struct ComposedSegmentInfo: Sendable {
    let composedStart: Double
    let composedEnd: Double
    let effects: SegmentEffects
}

/// Input for rendering burn-in subtitles into the composition.
///
/// `cues` are expressed in composed-timeline time (seconds from t=0 of the
/// final video). The `CompositionBuilder` forwards this to the renderer.
struct SubtitleBurnIn: Sendable {
    let cues: [ComposedSubtitle]
    let style: SubtitleStyle
}

/// Input for rendering the chapter progress bar into the composition.
/// `chapters` are expressed in composed-timeline seconds (post-cut),
/// matching how the `CMTime` playhead is reported.
struct ChapterBarBurnIn: Sendable {
    let chapters: [VideoChapter]
    let totalSeconds: Double
    let style: ChapterBarStyle

    init(chapters: [VideoChapter], totalSeconds: Double, style: ChapterBarStyle = .default) {
        self.chapters = chapters
        self.totalSeconds = totalSeconds
        self.style = style
    }
}

/// Builds AVMutableComposition + AVVideoComposition + AVMutableAudioMix
/// from timeline segments. Used by both preview and export paths.
struct CompositionBuilder: Sendable {
    private struct LoadedSource {
        let asset: AVURLAsset
        let video: AVAssetTrack
        let audio: AVAssetTrack?
    }

    struct Result: @unchecked Sendable {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition?
        let audioMix: AVMutableAudioMix?
        let videoTrack: AVMutableCompositionTrack
        let audioTrack: AVMutableCompositionTrack?
    }

    /// Build a full composition from segments.
    static func build(
        sourceLookup: @Sendable (UUID) -> URL,
        sourceKind: @Sendable (UUID) -> MediaKind = { _ in .video },
        segments: [TimelineSegment],
        auxAudioTracks: [Track] = [],
        overlayVideoTracks: [Track] = [],
        resolution: ExportResolution = .original,
        subtitleBurnIn: SubtitleBurnIn? = nil,
        chapterBurnIn: ChapterBarBurnIn? = nil,
        primaryHidden: Bool = false
    ) async throws -> Result {
        // Load all unique source videos
        let uniqueSourceIDs = Set(segments.map { $0.sourceVideoID })
        var sourceAssets: [UUID: LoadedSource] = [:]

        for sourceID in uniqueSourceIDs {
            // Skip image-kind sources: they have no AVAsset tracks. The
            // primary loop detects image segments via `sourceKind` and
            // renders them full-screen through the PiP compositor, so we
            // never need an AVURLAsset entry for them. Attempting to
            // `loadTracks` on an image file throws AVFoundation errors
            // that would abort the whole composition build.
            if sourceKind(sourceID) == .image {
                print("🖼️ CompositionBuilder: skipping asset load for image source \(sourceID)")
                continue
            }
            let url = sourceLookup(sourceID)
            print("🔧 CompositionBuilder: loading source \(sourceID) from \(url.path)")
            let asset = AVURLAsset(url: url)
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard let videoTrack = videoTracks.first else {
                print("🔴 CompositionBuilder: no video track in \(url.path) — skipping source \(sourceID)")
                continue
            }
            sourceAssets[sourceID] = LoadedSource(
                asset: asset,
                video: videoTrack,
                audio: audioTracks.first
            )
        }

        guard !sourceAssets.isEmpty || segments.contains(where: { sourceKind($0.sourceVideoID) == .image }) else {
            throw CompositionError.noVideoTrack
        }

        let composition = AVMutableComposition()

        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CompositionError.trackCreationFailed
        }

        // Add audio track if any source has audio
        let hasAnyAudio = sourceAssets.values.contains { $0.audio != nil }
        let compAudio: AVMutableCompositionTrack?
        if hasAnyAudio {
            compAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        } else {
            compAudio = nil
        }

        // Insert segments from their respective sources
        var insertTime = CMTime.zero
        var composedInfos: [ComposedSegmentInfo] = []
        // Primary-track image segments are collected here and merged
        // with overlay-image placements later so the PiP compositor
        // renders them full-screen during their time window. Declared
        // up here (instead of alongside the overlay lists below) so
        // the primary loop can push to it.
        struct PrimaryImagePlacement {
            let url: URL
            let composedStart: Double
            let composedEnd: Double
        }
        var primaryImagePlacements: [PrimaryImagePlacement] = []

        for segment in segments {
            // V1 image segment: the primary compositor pulls frames
            // from an AVAsset video track, which images don't have.
            // Fill the time slot on compVideo with a real video source
            // (any video in the project, scaled to fit), then overlay
            // the still full-screen via the PiP compositor. The filler
            // is never visible — the image overlay aspect-fits over a
            // full-canvas covering. We use a real video instead of
            // insertEmptyTimeRange because AVFoundation won't invoke
            // the custom compositor during time ranges where NO source
            // track has media, meaning the image overlay would never
            // render and the previous clip's last frame would linger.
            // Audio: untouched (images have no audio → silence).
            if sourceKind(segment.sourceVideoID) == .image {
                let targetDuration = CMTime(
                    seconds: max(0.05, segment.durationSeconds),
                    preferredTimescale: 600
                )
                let preInsertCompDuration = compVideo.timeRange.duration
                if let filler = sourceAssets.values.first {
                    let fillerTimeRange = filler.video.timeRange
                    let fillDuration = CMTimeMinimum(fillerTimeRange.duration, targetDuration)
                    // Use the filler track's actual start (not .zero) —
                    // some AVAssetTracks' timeRange doesn't begin at 0
                    // and requesting before the first frame misaligns
                    // the insert and desyncs downstream composition time.
                    let fillRange = CMTimeRange(start: fillerTimeRange.start, duration: fillDuration)
                    do {
                        try compVideo.insertTimeRange(fillRange, of: filler.video, at: insertTime)
                        let afterInsertCompDuration = compVideo.timeRange.duration
                        let actualInserted = CMTimeSubtract(afterInsertCompDuration, preInsertCompDuration)
                        if CMTimeCompare(actualInserted, targetDuration) != 0 {
                            compVideo.scaleTimeRange(
                                CMTimeRange(start: insertTime, duration: actualInserted),
                                toDuration: targetDuration
                            )
                        }
                    } catch {
                        print("🔴 V1-image: filler insert failed (\(error)) — falling back to empty range")
                        compVideo.insertEmptyTimeRange(
                            CMTimeRange(start: insertTime, duration: targetDuration)
                        )
                    }
                } else {
                    print("⚠️ V1-image: no filler video available, using insertEmptyTimeRange (compositor may not be invoked)")
                    compVideo.insertEmptyTimeRange(
                        CMTimeRange(start: insertTime, duration: targetDuration)
                    )
                }
                let composedStart = insertTime.seconds
                let composedEnd = CMTimeAdd(insertTime, targetDuration).seconds
                composedInfos.append(ComposedSegmentInfo(
                    composedStart: composedStart,
                    composedEnd: composedEnd,
                    effects: segment.effects
                ))
                let imageURL = sourceLookup(segment.sourceVideoID)
                primaryImagePlacements.append(PrimaryImagePlacement(
                    url: imageURL,
                    composedStart: composedStart,
                    composedEnd: composedEnd
                ))
                insertTime = CMTimeAdd(insertTime, targetDuration)
                continue
            }

            guard let source = sourceAssets[segment.sourceVideoID] else {
                print("🔴 CompositionBuilder: no source asset for segment \(segment.id) sourceVideoID=\(segment.sourceVideoID)")
                continue
            }

            // Clamp range to actual source track duration to avoid -12780 errors
            let sourceTrackDuration = source.video.timeRange.duration
            let sourceEnd = sourceTrackDuration.seconds

            let clampedStart = max(0, segment.range.startSeconds)
            let clampedEnd = min(sourceEnd, segment.range.endSeconds)
            guard clampedEnd > clampedStart + 0.01 else {
                print("⚠️ CompositionBuilder: skipping segment \(segment.id) — range \(segment.range.startSeconds)–\(segment.range.endSeconds)s exceeds source duration \(sourceEnd)s")
                continue
            }

            let start = CMTime(seconds: clampedStart, preferredTimescale: 600)
            let end = CMTime(seconds: clampedEnd, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: start, end: end)
            let insertedSourceDuration = CMTimeSubtract(end, start)
            let targetDuration = CMTime(
                seconds: segment.durationSeconds,
                preferredTimescale: 600
            )

            do {
                let hideVideo = segment.isVideoHidden || primaryHidden
                if hideVideo {
                    // Hidden primary: keep the time occupied so downstream
                    // segments don't shift left, but show black (or let an
                    // overlay above cover the window). An empty range is
                    // the cleanest way — no decode cost, no layer math.
                    compVideo.insertEmptyTimeRange(
                        CMTimeRange(start: insertTime, duration: insertedSourceDuration)
                    )
                } else {
                    try compVideo.insertTimeRange(timeRange, of: source.video, at: insertTime)
                }
            } catch {
                print("🔴 CompositionBuilder: video insert failed for \(segment.range.startSeconds)–\(segment.range.endSeconds)s: \(error)")
                continue
            }
            let insertedAudio = source.audio != nil
            if let sourceAudio = source.audio, let compAudio {
                try? compAudio.insertTimeRange(timeRange, of: sourceAudio, at: insertTime)
            }

            if abs(targetDuration.seconds - insertedSourceDuration.seconds) > 0.001 {
                let insertedRange = CMTimeRange(start: insertTime, duration: insertedSourceDuration)
                let hideVideo = segment.isVideoHidden || primaryHidden
                if !hideVideo {
                    compVideo.scaleTimeRange(insertedRange, toDuration: targetDuration)
                } else {
                    // Empty video ranges can't be scaled — resize by
                    // removing the placeholder gap and re-inserting at
                    // the target duration instead.
                    compVideo.removeTimeRange(insertedRange)
                    compVideo.insertEmptyTimeRange(
                        CMTimeRange(start: insertTime, duration: targetDuration)
                    )
                }
                if insertedAudio, let compAudio {
                    compAudio.scaleTimeRange(insertedRange, toDuration: targetDuration)
                }
            }

            let composedStart = insertTime.seconds
            let composedEnd = CMTimeAdd(insertTime, targetDuration).seconds
            composedInfos.append(ComposedSegmentInfo(
                composedStart: composedStart,
                composedEnd: composedEnd,
                effects: segment.effects
            ))

            insertTime = CMTimeAdd(insertTime, targetDuration)
        }

        // Preserve orientation from the first source
        if let firstSource = sourceAssets[segments.first?.sourceVideoID ?? UUID()] {
            compVideo.preferredTransform = try await firstSource.video.load(.preferredTransform)
        }

        // Insert overlay video tracks (B-roll / PiP). Each non-muted track
        // gets its own AVMutableCompositionTrack. Segments are placed at
        // their `placementOffset` when provided, otherwise flow after the
        // previous segment on the same track. NOTE: without explicit video
        // composition instructions AVFoundation picks the topmost opaque
        // track — last-inserted wins — which matches the user expectation
        // that B-roll fully replaces the primary during its window. Per-
        // track opacity / blending is a future enhancement.
        //
        // We also accumulate `overlayPlacements` here so the PiP compositor
        // backend (if engaged) can build per-interval instructions listing
        // which overlays + pipLayouts are active in each time range.
        struct OverlayPlacement {
            let trackID: CMPersistentTrackID
            let composedStart: Double
            let composedEnd: Double
            let pipLayout: PiPLayout?
            let freeTransform: FreeTransform?
        }
        /// Separate placement list for image-backed overlays. These do
        /// NOT get inserted into any AVMutableCompositionTrack — the
        /// custom PiP compositor reads them directly from disk via a
        /// CIImage cache. `requiredSourceTrackIDs` therefore excludes
        /// them (see `PiPCompositionInstruction.init`).
        struct ImageOverlayPlacement {
            let url: URL
            let composedStart: Double
            let composedEnd: Double
            let pipLayout: PiPLayout?
            let freeTransform: FreeTransform?
        }
        var overlayCompTracks: [AVMutableCompositionTrack] = []
        var overlayPlacements: [OverlayPlacement] = []
        var imageOverlayPlacements: [ImageOverlayPlacement] = []
        for overlay in overlayVideoTracks where !overlay.isMuted {
            guard !overlay.segments.isEmpty else { continue }

            // Split image vs video segments up-front. Image segments are
            // never inserted into an AV track — they're gathered into
            // imageOverlayPlacements for the custom compositor. Video
            // segments flow through the existing insert path below.
            //
            // Two advantages:
            // 1. A track full of images doesn't waste an AVMutableTrack
            //    slot (and doesn't need a phantom source AVAsset).
            // 2. We can still honor placementOffset for images — no need
            //    to pretend they're on a track cursor.
            let imageSegments = overlay.segments.filter { sourceKind($0.sourceVideoID) == .image }
            let videoSegments = overlay.segments.filter { sourceKind($0.sourceVideoID) != .image }

            // Image segments: each one stands alone (no per-track cursor
            // — images on overlay lanes are always anchored by
            // placementOffset when the UI drops them). If missing, fall
            // back to 0 so we at least render something visible.
            for segment in imageSegments {
                let url = sourceLookup(segment.sourceVideoID)
                let composedStart = segment.placementOffset ?? 0
                let composedEnd = composedStart + max(0, segment.durationSeconds)
                guard composedEnd > composedStart + 0.01 else { continue }
                print("🖼️ overlay-image: segID=\(segment.id) src=\(segment.sourceVideoID) composed=[\(composedStart)..\(composedEnd)] url=\(url.lastPathComponent)")
                imageOverlayPlacements.append(ImageOverlayPlacement(
                    url: url,
                    composedStart: composedStart,
                    composedEnd: composedEnd,
                    pipLayout: segment.pipLayout,
                    freeTransform: segment.freeTransform
                ))
            }

            // If the lane is image-only, skip allocating an AV track.
            guard !videoSegments.isEmpty else { continue }

            guard let overlayCompTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            var overlayCursor = CMTime.zero
            for segment in videoSegments {
                let url = sourceLookup(segment.sourceVideoID)
                let asset = AVURLAsset(url: url)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoAsset = videoTracks.first else { continue }

                let sourceDuration = videoAsset.timeRange.duration.seconds
                let clampedStart = max(0, segment.range.startSeconds)
                let clampedEnd = min(sourceDuration, segment.range.endSeconds)
                guard clampedEnd > clampedStart + 0.01 else { continue }

                let start = CMTime(seconds: clampedStart, preferredTimescale: 600)
                let end = CMTime(seconds: clampedEnd, preferredTimescale: 600)
                let timeRange = CMTimeRange(start: start, end: end)
                let targetDuration = CMTime(
                    seconds: segment.durationSeconds,
                    preferredTimescale: 600
                )

                let insertAt: CMTime = {
                    if let anchor = segment.placementOffset {
                        return CMTime(seconds: anchor, preferredTimescale: 600)
                    }
                    return overlayCursor
                }()

                do {
                    if segment.isVideoHidden {
                        // Skip the insert entirely — overlay is supposed to
                        // cover V1 during its window, so "hidden" just
                        // means "let V1 show through here". We still
                        // advance the cursor below so following segments
                        // on the same overlay track keep their intended
                        // composed-start positions.
                    } else {
                        try overlayCompTrack.insertTimeRange(timeRange, of: videoAsset, at: insertAt)
                    }
                } catch {
                    print("🔴 CompositionBuilder: overlay video insert failed: \(error)")
                    continue
                }
                if !segment.isVideoHidden,
                   abs(targetDuration.seconds - (end.seconds - start.seconds)) > 0.001 {
                    let insertedRange = CMTimeRange(
                        start: insertAt,
                        duration: CMTimeSubtract(end, start)
                    )
                    overlayCompTrack.scaleTimeRange(insertedRange, toDuration: targetDuration)
                }

                if !segment.isVideoHidden {
                    overlayPlacements.append(OverlayPlacement(
                        trackID: overlayCompTrack.trackID,
                        composedStart: insertAt.seconds,
                        composedEnd: CMTimeAdd(insertAt, targetDuration).seconds,
                        pipLayout: segment.pipLayout,
                        freeTransform: segment.freeTransform
                    ))
                }

                overlayCursor = CMTimeAdd(insertAt, targetDuration)
            }

            if let firstSegmentSource = sourceAssets[videoSegments.first?.sourceVideoID ?? UUID()] {
                overlayCompTrack.preferredTransform = try await firstSegmentSource.video.load(.preferredTransform)
            } else if let firstSeg = videoSegments.first,
                      let overlayAsset = try? await AVURLAsset(url: sourceLookup(firstSeg.sourceVideoID)).loadTracks(withMediaType: .video).first {
                overlayCompTrack.preferredTransform = try await overlayAsset.load(.preferredTransform)
            }

            overlayCompTracks.append(overlayCompTrack)
        }

        // Does this composition need the custom PiP backend? Engage it
        // whenever *any* video overlay placement exists (full-cover
        // animation overlays, B-roll, PiP, free transform), any image
        // overlay is present, or a primary image segment exists.
        //
        // Without the PiP backend AVFoundation has no instructions for
        // how to layer v2 on top of v1, so overlays without an explicit
        // layout (e.g. Remotion ProRes 4444 animations that are meant
        // to cover the frame with alpha) end up hidden behind the
        // primary track.
        let needsPiPBackend = !overlayPlacements.isEmpty
            || !imageOverlayPlacements.isEmpty
            || !primaryImagePlacements.isEmpty

        // Build video composition if any segment has visual effects, a
        // resolution override, or subtitle burn-in is requested.
        let hasVisualEffects = segments.contains { !$0.effects.isDefault || $0.effects.hasAnyVisualEffect }
        let needsResolutionOverride = resolution != .original
        let needsSubtitleBurnIn = subtitleBurnIn != nil
        let needsChapterBurnIn = chapterBurnIn != nil

        var videoComp: AVMutableVideoComposition?
        if hasVisualEffects || needsResolutionOverride || needsSubtitleBurnIn || needsChapterBurnIn || needsPiPBackend {
            // Use first source for render dimensions
            let firstSourceVideo = sourceAssets[segments.first?.sourceVideoID ?? UUID()]?.video
            let sourceTransform: CGAffineTransform
            let naturalSize: CGSize
            let nominalFPS: Float
            if let firstSourceVideo {
                sourceTransform = try await firstSourceVideo.load(.preferredTransform)
                naturalSize = try await firstSourceVideo.load(.naturalSize)
                nominalFPS = try await firstSourceVideo.load(.nominalFrameRate)
            } else {
                sourceTransform = .identity
                naturalSize = CGSize(width: 1920, height: 1080)
                nominalFPS = 30
            }

            let orientedSize = naturalSize.applying(sourceTransform)
            let sourceWidth = abs(orientedSize.width)
            let sourceHeight = abs(orientedSize.height)

            // Calculate render size
            let renderSize: CGSize
            if let targetH = resolution.targetHeight {
                let scale = CGFloat(targetH) / sourceHeight
                renderSize = CGSize(
                    width: ceil(sourceWidth * scale / 2) * 2,
                    height: CGFloat(targetH)
                )
            } else {
                renderSize = CGSize(width: sourceWidth, height: sourceHeight)
            }

            let fps = nominalFPS > 0 ? nominalFPS : 30

            // Build the subtitle renderer up-front so the filter closure only
            // carries an immutable Sendable value.
            let subtitleRenderer: SubtitleBurnInRenderer? = subtitleBurnIn.map { burn in
                // Normalize the style's locale before the dictionary
                // lookup — the translate tool writes under the
                // canonical form, so legacy / hand-written styles must
                // match or the second line silently disappears.
                let secondaryLocale: String? = {
                    guard let raw = burn.style.bilingual?.secondaryLocale else { return nil }
                    let normalized = BilingualDisplayOptions.normalizeLocale(raw)
                    return normalized.isEmpty ? nil : normalized
                }()
                return SubtitleBurnInRenderer(
                    cues: burn.cues.map { cue in
                        let secondary = secondaryLocale.flatMap {
                            cue.translations[$0]
                        }
                        return .init(
                            startSeconds: cue.startSeconds,
                            endSeconds: cue.endSeconds,
                            text: cue.text,
                            secondaryText: secondary,
                            runs: cue.runs,
                            styleOverride: cue.styleOverride
                        )
                    },
                    style: burn.style,
                    renderSize: renderSize
                )
            }

            let chapterRenderer: ChapterBarBurnInRenderer? = chapterBurnIn.map { burn in
                ChapterBarBurnInRenderer(
                    chapters: burn.chapters,
                    totalSeconds: burn.totalSeconds,
                    renderSize: renderSize,
                    style: burn.style
                )
            }

            if needsPiPBackend {
                // Custom AVVideoCompositing backend: per-frame primary +
                // overlay composite with shape mask + effects.
                let vc = AVMutableVideoComposition()
                vc.customVideoCompositorClass = PiPVideoCompositor.self
                vc.renderSize = renderSize
                vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                vc.instructions = Self.buildPiPInstructions(
                    primaryTrackID: compVideo.trackID,
                    overlayPlacements: overlayPlacements.map {
                        PiPInstructionPlacement(
                            source: .track($0.trackID),
                            composedStart: $0.composedStart,
                            composedEnd: $0.composedEnd,
                            pipLayout: $0.pipLayout,
                            freeTransform: $0.freeTransform
                        )
                    } + imageOverlayPlacements.map {
                        PiPInstructionPlacement(
                            source: .image(url: $0.url),
                            composedStart: $0.composedStart,
                            composedEnd: $0.composedEnd,
                            pipLayout: $0.pipLayout,
                            freeTransform: $0.freeTransform
                        )
                    } + primaryImagePlacements.map {
                        // V1 image segments render full-screen (no
                        // pipLayout/freeTransform). The PiP compositor
                        // aspect-fits them over the black empty range
                        // reserved on the primary track.
                        PiPInstructionPlacement(
                            source: .image(url: $0.url),
                            composedStart: $0.composedStart,
                            composedEnd: $0.composedEnd,
                            pipLayout: nil,
                            freeTransform: nil
                        )
                    },
                    totalDuration: max(
                        insertTime.seconds,
                        overlayPlacements.map(\.composedEnd).max() ?? 0,
                        imageOverlayPlacements.map(\.composedEnd).max() ?? 0
                    ),
                    composedInfos: composedInfos,
                    subtitleRenderer: subtitleRenderer,
                    chapterRenderer: chapterRenderer
                )
                videoComp = vc
            } else {
                let vc = AVMutableVideoComposition(
                    asset: composition,
                    applyingCIFiltersWithHandler: { request in
                        Self.applyEffects(
                            request: request,
                            composedInfos: composedInfos,
                            renderSize: renderSize,
                            subtitleRenderer: subtitleRenderer,
                            chapterRenderer: chapterRenderer
                        )
                    }
                )
                vc.renderSize = renderSize
                vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                videoComp = vc
            }
        }

        // Build audio mix — primary audio plus any aux audio tracks.
        var allMixParams: [AVMutableAudioMixInputParameters] = []
        if let compAudio {
            if primaryHidden {
                // Eye-off on V1 hides the picture AND silences audio.
                // We still need to emit params so the mix wins over the
                // default full-volume render.
                let muted = AVMutableAudioMixInputParameters(track: compAudio)
                muted.setVolume(0, at: .zero)
                allMixParams.append(muted)
            } else if let primaryParams = Self.buildAudioMixInputParams(
                segments: segments,
                audioTrack: compAudio
            ) {
                allMixParams.append(primaryParams)
            }
        }

        // Insert aux audio tracks (BGM, narration, etc.) as additional
        // composition audio lanes. Each gets its own AVMutableCompositionTrack
        // and AVMutableAudioMixInputParameters; the final AVMutableAudioMix
        // aggregates them so they play simultaneously with the primary.
        for aux in auxAudioTracks where !aux.isMuted {
            guard !aux.segments.isEmpty else { continue }
            guard let auxCompTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            // Honor per-segment `placementOffset` the same way overlay
            // video does — this is what lets Detach Audio anchor a
            // mirror segment to its V1 clip's composed-time position,
            // instead of flowing sequentially on the aux lane.
            var auxCursor = CMTime.zero
            for segment in aux.segments {
                let url = sourceLookup(segment.sourceVideoID)
                let asset = AVURLAsset(url: url)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard let audioAsset = audioTracks.first else { continue }

                let sourceDuration = audioAsset.timeRange.duration.seconds
                let clampedStart = max(0, segment.range.startSeconds)
                let clampedEnd = min(sourceDuration, segment.range.endSeconds)
                guard clampedEnd > clampedStart + 0.01 else { continue }

                let start = CMTime(seconds: clampedStart, preferredTimescale: 600)
                let end = CMTime(seconds: clampedEnd, preferredTimescale: 600)
                let timeRange = CMTimeRange(start: start, end: end)
                let targetDuration = CMTime(
                    seconds: segment.durationSeconds,
                    preferredTimescale: 600
                )

                let insertAt: CMTime = {
                    if let anchor = segment.placementOffset {
                        return CMTime(seconds: anchor, preferredTimescale: 600)
                    }
                    return auxCursor
                }()

                do {
                    try auxCompTrack.insertTimeRange(timeRange, of: audioAsset, at: insertAt)
                } catch {
                    print("🔴 CompositionBuilder: aux audio insert failed: \(error)")
                    continue
                }
                if abs(targetDuration.seconds - (end.seconds - start.seconds)) > 0.001 {
                    let insertedRange = CMTimeRange(
                        start: insertAt,
                        duration: CMTimeSubtract(end, start)
                    )
                    auxCompTrack.scaleTimeRange(insertedRange, toDuration: targetDuration)
                }
                auxCursor = CMTimeAdd(insertAt, targetDuration)
            }

            if let auxParams = Self.buildAudioMixInputParams(
                segments: aux.segments,
                audioTrack: auxCompTrack
            ) {
                allMixParams.append(auxParams)
            }
        }

        let audioMix: AVMutableAudioMix?
        if allMixParams.isEmpty {
            audioMix = nil
        } else {
            let mix = AVMutableAudioMix()
            mix.inputParameters = allMixParams
            audioMix = mix
        }

        return Result(
            composition: composition,
            videoComposition: videoComp,
            audioMix: audioMix,
            videoTrack: compVideo,
            audioTrack: compAudio
        )
    }

    // MARK: - PiP instructions

    struct PiPInstructionPlacement {
        /// Matches `PiPCompositionInstruction.OverlayEntry.Source`; the
        /// two types are kept separate so the composition layer doesn't
        /// import AV types on the PiP instruction's naming of it.
        enum Source {
            case track(CMPersistentTrackID)
            case image(url: URL)
        }
        let source: Source
        let composedStart: Double
        let composedEnd: Double
        let pipLayout: PiPLayout?
        let freeTransform: FreeTransform?
    }

    /// Build a list of `PiPCompositionInstruction`s covering `[0, totalDuration)`.
    ///
    /// Algorithm: collect every unique boundary point (0, totalDuration,
    /// and every overlay start/end) → sort → emit one instruction per
    /// adjacent pair. For each interval, an overlay is "active" if its
    /// composed range fully covers the interval midpoint.
    static func buildPiPInstructions(
        primaryTrackID: CMPersistentTrackID,
        overlayPlacements: [PiPInstructionPlacement],
        totalDuration: Double,
        composedInfos: [ComposedSegmentInfo],
        subtitleRenderer: SubtitleBurnInRenderer?,
        chapterRenderer: ChapterBarBurnInRenderer?
    ) -> [PiPCompositionInstruction] {
        guard totalDuration > 0 else { return [] }

        var boundaries = Set<Double>([0, totalDuration])
        for p in overlayPlacements {
            boundaries.insert(max(0, p.composedStart))
            boundaries.insert(min(totalDuration, p.composedEnd))
        }
        let sorted = boundaries.sorted()

        var result: [PiPCompositionInstruction] = []
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            guard b - a > 0.0005 else { continue }
            let mid = (a + b) / 2
            let activeOverlays = overlayPlacements
                .filter { $0.composedStart <= mid && mid < $0.composedEnd }
                .map { placement -> PiPCompositionInstruction.OverlayEntry in
                    let source: PiPCompositionInstruction.OverlayEntry.Source
                    switch placement.source {
                    case let .track(id): source = .track(id)
                    case let .image(url): source = .image(url: url)
                    }
                    return PiPCompositionInstruction.OverlayEntry(
                        source: source,
                        pipLayout: placement.pipLayout,
                        freeTransform: placement.freeTransform
                    )
                }

            let range = CMTimeRange(
                start: CMTime(seconds: a, preferredTimescale: 600),
                end: CMTime(seconds: b, preferredTimescale: 600)
            )
            result.append(PiPCompositionInstruction(
                timeRange: range,
                primaryTrackID: primaryTrackID,
                overlays: activeOverlays,
                composedInfos: composedInfos,
                subtitleRenderer: subtitleRenderer,
                chapterRenderer: chapterRenderer
            ))
        }
        return result
    }

    // MARK: - CIFilter Effects Handler

    private static func applyEffects(
        request: AVAsynchronousCIImageFilteringRequest,
        composedInfos: [ComposedSegmentInfo],
        renderSize: CGSize,
        subtitleRenderer: SubtitleBurnInRenderer?,
        chapterRenderer: ChapterBarBurnInRenderer? = nil
    ) {
        let image = CompositionEffectRenderer.applyEffects(
            to: request.sourceImage,
            at: request.compositionTime.seconds,
            composedInfos: composedInfos,
            renderSize: renderSize,
            subtitleRenderer: subtitleRenderer,
            chapterRenderer: chapterRenderer
        )
        request.finish(with: image, context: nil)
    }

    // MARK: - Audio Mix

    static func buildAudioMix(
        segments: [TimelineSegment],
        audioTrack: AVMutableCompositionTrack?
    ) -> AVMutableAudioMix? {
        guard let params = buildAudioMixInputParams(
            segments: segments,
            audioTrack: audioTrack
        ) else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    /// Build the per-track audio-mix parameters for one logical audio lane
    /// (primary or aux). Exposed separately so the composition builder can
    /// aggregate multiple lanes into a single AVMutableAudioMix when the
    /// project has BGM / narration tracks on top of the primary audio.
    static func buildAudioMixInputParams(
        segments: [TimelineSegment],
        audioTrack: AVMutableCompositionTrack?
    ) -> AVMutableAudioMixInputParameters? {
        guard let audioTrack else { return nil }

        let params = AVMutableAudioMixInputParameters(track: audioTrack)

        // Compute each segment's composed-start time using the same
        // placementOffset-aware cursor logic that the insertion loops
        // use. Without this, a detached-audio segment anchored at
        // t=10s via placementOffset would have its volume/fade ramps
        // placed at t=0s — producing a silent clip in the export.
        var cursor = CMTime.zero
        for segment in segments {
            let segDuration = CMTime(
                seconds: segment.durationSeconds,
                preferredTimescale: 600
            )
            let offset: CMTime = {
                if let anchor = segment.placementOffset {
                    return CMTime(seconds: anchor, preferredTimescale: 600)
                }
                return cursor
            }()
            let segEnd = CMTimeAdd(offset, segDuration)
            let vol = Float(segment.volumeLevel)

            // Clamp fades to at most half the segment so a fade-in and
            // fade-out never overlap on short clips.
            let rawFadeIn = segment.effects.audioFadeInDuration
            let rawFadeOut = segment.effects.audioFadeOutDuration
            let fadeInDur = rawFadeIn > 0
                ? min(rawFadeIn, segment.durationSeconds / 2) : 0
            let fadeOutDur = rawFadeOut > 0
                ? min(rawFadeOut, segment.durationSeconds / 2) : 0

            let holdStart = CMTimeAdd(offset, CMTime(seconds: fadeInDur, preferredTimescale: 600))
            let holdEnd = CMTimeSubtract(segEnd, CMTime(seconds: fadeOutDur, preferredTimescale: 600))

            if fadeInDur > 0 {
                params.setVolumeRamp(
                    fromStartVolume: 0,
                    toEndVolume: vol,
                    timeRange: CMTimeRange(start: offset, end: holdStart)
                )
            }

            // Anchor the volume at a flat level across the hold portion.
            // Without this, AVFoundation linearly interpolates between
            // this segment's setVolume point and the next segment's —
            // which manifests as a gradual fade instead of a hard mute
            // when neighbouring segments have different volumeLevels.
            if CMTimeCompare(holdEnd, holdStart) > 0 {
                params.setVolumeRamp(
                    fromStartVolume: vol,
                    toEndVolume: vol,
                    timeRange: CMTimeRange(start: holdStart, end: holdEnd)
                )
            } else {
                // Degenerate case: fadeIn + fadeOut cover the whole
                // segment. Drop a point at the midpoint so the fades
                // still pivot through `vol` rather than interpolating
                // directly between 0 and 0.
                params.setVolume(vol, at: holdStart)
            }

            if fadeOutDur > 0 {
                params.setVolumeRamp(
                    fromStartVolume: vol,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(start: holdEnd, end: segEnd)
                )
            }

            cursor = segEnd
        }

        return params
    }

    // MARK: - Errors

    enum CompositionError: Error, LocalizedError {
        case noVideoTrack
        case trackCreationFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "Source video has no video track."
            case .trackCreationFailed: return "Could not create composition track."
            }
        }
    }
}
