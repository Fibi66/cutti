import Foundation
import AVFoundation
import CoreImage
import UIKit
import CuttiKit

/// Builds an `AVMutableComposition` that plays the primary video
/// track's segments back-to-back, each clipped to its source `range`.
/// Overlay / effects / speed-rate are out of scope for this MVP —
/// macOS's `CompositionBuilder` is the canonical renderer for full
/// fidelity; iOS only needs enough here to preview imports and simple
/// cuts.
enum IOSCompositionBuilder {

    /// Build a composition from the given primary-track segments +
    /// media manifest. Returns nil when there's nothing playable.
    @MainActor
    static func build(
        primarySegments: [TimelineSegment],
        overlaySegments: [TimelineSegment] = [],
        manifest: MediaManifest,
        projectRoot: URL,
        visualEffects: [UUID: ProjectDocument.VisualEffectPreset] = [:],
        textOverlays: [IOSSessionState.TextOverlay] = [],
        transitions: [UUID: Double] = [:]
    ) -> AVPlayerItem? {
        guard !primarySegments.isEmpty else { return nil }

        let mediaByID = Dictionary(uniqueKeysWithValues: manifest.media.map { ($0.id, $0) })
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor: CMTime = .zero
        var appended = 0
        let audioMixInputs: NSMutableArray = []
        var visualPlans: [SegmentVisual] = []

        for segment in primarySegments {
            guard let asset = mediaByID[segment.sourceVideoID] else { continue }
            let url = resolveURL(for: asset, projectRoot: projectRoot)
            let avAsset = AVURLAsset(url: url)

            let start = CMTime(seconds: segment.range.startSeconds, preferredTimescale: 600)
            let end = CMTime(seconds: segment.range.endSeconds, preferredTimescale: 600)
            let range = CMTimeRange(start: start, end: end)
            guard range.duration > .zero else { continue }

            // Use the synchronous tracks API here — the player item is
            // only used on the main thread for preview, and all media
            // is local so loading is cheap.
            let sourceVideoTracks = avAsset.tracks(withMediaType: .video)
            let sourceAudioTracks = avAsset.tracks(withMediaType: .audio)

            if let source = sourceVideoTracks.first {
                do {
                    try videoTrack.insertTimeRange(range, of: source, at: cursor)
                } catch {
                    continue
                }
            } else {
                continue
            }

            if let audioTrack, let source = sourceAudioTracks.first {
                try? audioTrack.insertTimeRange(range, of: source, at: cursor)
                // Build audio mix params respecting volume + fades.
                let insertedRange = CMTimeRange(start: cursor, duration: range.duration)
                if let params = audioMixParams(
                    forTrack: audioTrack,
                    baseVolume: Float(segment.volumeLevel),
                    fadeIn: segment.effects.audioFadeInDuration,
                    fadeOut: segment.effects.audioFadeOutDuration,
                    insertedRange: insertedRange
                ) {
                    audioMixInputs.add(params)
                }
            }

            cursor = CMTimeAdd(cursor, range.duration)
            appended += 1
            visualPlans.append(SegmentVisual(
                composedRange: CMTimeRange(
                    start: CMTimeSubtract(cursor, range.duration),
                    duration: range.duration
                ),
                effects: segment.effects,
                visualPreset: visualEffects[segment.id] ?? .none,
                fadeOutSeconds: transitions[segment.id] ?? 0
            ))
        }

        // Transition durations are declared on the *outgoing* segment,
        // but the symmetric fade-up also needs to live on the incoming
        // segment. Walk adjacent plans and copy each N's fadeOut into
        // N+1's fadeIn. Also clamp to half each segment's duration so
        // a user with aggressive 2s fades on 1s clips doesn't end up
        // with plan.duration < fadeIn+fadeOut (which would produce
        // negative alpha windows).
        // Transition durations are declared on the *outgoing* segment,
        // but the symmetric fade-up also needs to live on the incoming
        // segment. Walk adjacent plans and copy each N's fadeOut into
        // N+1's fadeIn. Also clamp to half each segment's duration so
        // a user with aggressive 2s fades on 1s clips doesn't end up
        // with plan.duration < fadeIn+fadeOut (which would produce
        // negative alpha windows).
        //
        // NOTE: iterate via `indices.dropFirst()` rather than
        // `1..<visualPlans.count`. When every segment above took a
        // `continue` path (missing media, zero-duration range, insert
        // failure) visualPlans is empty and `1..<0` traps in Range's
        // precondition before we ever reach the `appended > 0` guard
        // below. That was the SIGTRAP users hit when the preview pane
        // tried to refresh against a project whose sole clip's media
        // file was unresolvable.
        for i in visualPlans.indices.dropFirst() {
            let prevOut = visualPlans[i - 1].fadeOutSeconds
            if prevOut > 0 {
                visualPlans[i].fadeInSeconds = prevOut
            }
        }
        for i in visualPlans.indices {
            let halfDur = visualPlans[i].composedRange.duration.seconds / 2
            visualPlans[i].fadeInSeconds = min(visualPlans[i].fadeInSeconds, halfDur)
            visualPlans[i].fadeOutSeconds = min(visualPlans[i].fadeOutSeconds, halfDur)
        }
        // Last segment can't fade out (nothing to fade into) so drop.
        if !visualPlans.isEmpty {
            visualPlans[visualPlans.count - 1].fadeOutSeconds = 0
        }

        guard appended > 0 else { return nil }

        // Insert overlay-track segments, each onto its own new
        // AVMutableCompositionTrack so the custom compositor can address
        // them by trackID. Anchored by placementOffset; no audio (overlay
        // tracks contribute picture only on iOS).
        var overlayPlans: [IOSPiPOverlayPlan] = []
        let primaryDuration = cursor
        for segment in overlaySegments {
            guard let asset = mediaByID[segment.sourceVideoID] else { continue }
            let start = CMTime(seconds: segment.range.startSeconds, preferredTimescale: 600)
            let end = CMTime(seconds: segment.range.endSeconds, preferredTimescale: 600)
            let range = CMTimeRange(start: start, end: end)
            guard range.duration > .zero else { continue }

            let url = resolveURL(for: asset, projectRoot: projectRoot)
            let avAsset = AVURLAsset(url: url)
            guard let source = avAsset.tracks(withMediaType: .video).first else { continue }
            guard let overlayTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let at = CMTime(seconds: max(0, segment.placementOffset ?? 0), preferredTimescale: 600)
            do {
                try overlayTrack.insertTimeRange(range, of: source, at: at)
            } catch {
                continue
            }
            overlayPlans.append(IOSPiPOverlayPlan(
                trackID: overlayTrack.trackID,
                composedRange: CMTimeRange(start: at, duration: range.duration),
                pipLayout: segment.pipLayout,
                freeTransform: segment.freeTransform
            ))
        }

        // Convert to the immutable `AVComposition` which is `Sendable`
        // under Swift 6 strict concurrency (`AVMutableComposition` is
        // not).
        let immutable = composition.copy() as! AVComposition
        let item = AVPlayerItem(asset: immutable)
        if audioMixInputs.count > 0 {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioMixInputs.compactMap { $0 as? AVAudioMixInputParameters }
            item.audioMix = mix
        }
        if !overlayPlans.isEmpty {
            // Multi-track PiP path: use the custom compositor so overlay
            // frames can be transformed + masked on top of primary.
            let primaryTrackID = immutable.tracks(withMediaType: .video).first?.trackID
            let totalDuration = max(
                primaryDuration,
                overlayPlans.map { CMTimeAdd($0.composedRange.start, $0.composedRange.duration) }.max() ?? .zero
            )
            let vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = IOSPiPCompositor.self
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            // Derive render size from the primary track's natural size
            // (fall back to 1920x1080 if unreadable).
            let renderSize: CGSize = {
                if let pt = immutable.tracks(withMediaType: .video).first {
                    let n = pt.naturalSize
                    if n.width > 0 && n.height > 0 { return n }
                }
                return CGSize(width: 1920, height: 1080)
            }()
            vc.renderSize = renderSize
            vc.instructions = [IOSPiPInstruction(
                timeRange: CMTimeRange(start: .zero, duration: totalDuration),
                primaryTrackID: primaryTrackID,
                primaryPlans: visualPlans,
                overlays: overlayPlans,
                textOverlays: textOverlays
            )]
            item.videoComposition = vc
        } else if let vc = buildVideoComposition(asset: immutable, plans: visualPlans, textOverlays: textOverlays) {
            item.videoComposition = vc
        }
        return item
    }

    static func resolveURL(
        for asset: MediaAssetRecord,
        projectRoot: URL
    ) -> URL {
        if let proxyRel = asset.derived.proxyRelativePath {
            let proxyURL = projectRoot.appending(path: proxyRel)
            if FileManager.default.fileExists(atPath: proxyURL.path) {
                return proxyURL
            }
        }
        return URL(fileURLWithPath: asset.sourcePath)
    }

    /// Build `AVMutableAudioMixInputParameters` for one inserted
    /// segment. Applies base volume + optional fade-in/out ramps
    /// relative to the segment's placement in the composition.
    /// Returns nil when no audio adjustment is needed (avoid bloating
    /// the mix with no-op entries).
    static func audioMixParams(
        forTrack track: AVCompositionTrack,
        baseVolume: Float,
        fadeIn: Double,
        fadeOut: Double,
        insertedRange: CMTimeRange
    ) -> AVMutableAudioMixInputParameters? {
        let hasFade = fadeIn > 0 || fadeOut > 0
        let hasVol = abs(baseVolume - 1.0) > 0.001
        guard hasFade || hasVol else { return nil }

        let params = AVMutableAudioMixInputParameters(track: track)
        let start = insertedRange.start
        let end = CMTimeAdd(start, insertedRange.duration)

        if fadeIn > 0 {
            let fi = min(fadeIn, CMTimeGetSeconds(insertedRange.duration) / 2)
            let fiEnd = CMTimeAdd(start, CMTime(seconds: fi, preferredTimescale: 600))
            params.setVolumeRamp(fromStartVolume: 0,
                                 toEndVolume: baseVolume,
                                 timeRange: CMTimeRange(start: start, end: fiEnd))
            // Hold after fade-in
            let holdEnd = fadeOut > 0
                ? CMTimeSubtract(end, CMTime(seconds: min(fadeOut, CMTimeGetSeconds(insertedRange.duration) / 2),
                                             preferredTimescale: 600))
                : end
            if CMTimeCompare(fiEnd, holdEnd) < 0 {
                params.setVolumeRamp(fromStartVolume: baseVolume,
                                     toEndVolume: baseVolume,
                                     timeRange: CMTimeRange(start: fiEnd, end: holdEnd))
            }
        } else if hasVol {
            // No fade-in, but still need to establish base volume at
            // the segment's start (so it doesn't default to 1.0).
            let holdEnd = fadeOut > 0
                ? CMTimeSubtract(end, CMTime(seconds: min(fadeOut, CMTimeGetSeconds(insertedRange.duration) / 2),
                                             preferredTimescale: 600))
                : end
            params.setVolumeRamp(fromStartVolume: baseVolume,
                                 toEndVolume: baseVolume,
                                 timeRange: CMTimeRange(start: start, end: holdEnd))
        }

        if fadeOut > 0 {
            let fo = min(fadeOut, CMTimeGetSeconds(insertedRange.duration) / 2)
            let foStart = CMTimeSubtract(end, CMTime(seconds: fo, preferredTimescale: 600))
            params.setVolumeRamp(fromStartVolume: baseVolume,
                                 toEndVolume: 0,
                                 timeRange: CMTimeRange(start: foStart, end: end))
        }

        return params
    }

    /// Per-segment visual plan: the composed time-range and the
    /// effects (brightness/contrast/saturation/rotation/flip) to apply
    /// while that segment is on-screen.
    struct SegmentVisual {
        let composedRange: CMTimeRange
        let effects: SegmentEffects
        var visualPreset: ProjectDocument.VisualEffectPreset = .none
        /// Length of the fade-from-black window at the start of this
        /// composed range (the previous segment had an exit transition).
        var fadeInSeconds: Double = 0
        /// Length of the fade-to-black window at the end of this
        /// composed range (this segment has an exit transition).
        var fadeOutSeconds: Double = 0
    }

    /// Build an `AVMutableVideoComposition` that applies per-segment
    /// CIColorControls (brightness/contrast/saturation) and simple
    /// mirror flips whenever the active segment's effects deviate from
    /// defaults. Returns nil when no segment needs any visual effect
    /// (keeps the composition cheap: AVFoundation plays the raw
    /// decoded frames without our CIImage round-trip).
    ///
    /// When `exportCanvas` is non-nil the composition is always built
    /// and runs inside that fixed render size: the source frame is
    /// aspect-fit into the canvas, and the surrounding letterbox is
    /// filled using the supplied `BackgroundStyle` (solid colour or a
    /// blurred aspect-fill of the same source). That path is used by
    /// `IOSExportService` so the exported MP4 honours the user's
    /// chosen aspect ratio + background.
    /// Chapter progress-bar burn-in spec. When non-nil, the renderer
    /// is built once and overlayed at every frame inside the
    /// CIFilters handler. Times are composed-timeline seconds.
    struct ChapterBurnIn {
        let chapters: [VideoChapter]
        let totalSeconds: Double
        let style: ChapterBarStyle
    }

    static func buildVideoComposition(
        asset: AVAsset,
        plans: [SegmentVisual],
        exportCanvas: (renderSize: CGSize, background: ProjectDocument.BackgroundStyle)? = nil,
        textOverlays: [IOSSessionState.TextOverlay] = [],
        chapterBurnIn: ChapterBurnIn? = nil
    ) -> AVMutableVideoComposition? {
        let needed = plans.contains(where: {
            needsEffect($0.effects)
                || $0.visualPreset != .none
                || $0.fadeInSeconds > 0
                || $0.fadeOutSeconds > 0
        })
        let hasChapters = chapterBurnIn.map { !$0.chapters.isEmpty } ?? false
        if exportCanvas == nil && !needed && textOverlays.isEmpty && !hasChapters { return nil }

        let chapterRenderer: ChapterBarBurnInRenderer? = chapterBurnIn.flatMap { burn in
            guard !burn.chapters.isEmpty else { return nil }
            let size = exportCanvas?.renderSize
                ?? CGSize(width: 1920, height: 1080)
            return ChapterBarBurnInRenderer(
                chapters: burn.chapters,
                totalSeconds: burn.totalSeconds,
                renderSize: size,
                style: burn.style
            )
        }

        let vc = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { request in
                let t = request.compositionTime
                let plan = plans.first(where: { CMTimeRangeContainsTime($0.composedRange, time: t) })
                    ?? plans.last
                var image = request.sourceImage.clampedToExtent()
                let extent = request.sourceImage.extent
                if let plan {
                    if needsEffect(plan.effects) {
                        image = applyColor(image, effects: plan.effects)
                        image = applyFlip(image, effects: plan.effects, extent: extent)
                        image = applyRotation(image, effects: plan.effects, extent: extent)
                    }
                    if plan.visualPreset != .none {
                        image = applyVisualPreset(image, preset: plan.visualPreset, extent: extent)
                    }
                    if plan.fadeInSeconds > 0 || plan.fadeOutSeconds > 0 {
                        image = applyTransitionFade(image, plan: plan, time: t, extent: extent)
                    }
                }

                if let canvas = exportCanvas {
                    let canvasRect = CGRect(origin: .zero, size: canvas.renderSize)
                    let bg = makeBackground(
                        source: image,
                        sourceExtent: extent,
                        canvas: canvasRect,
                        style: canvas.background
                    )
                    let foreground = aspectFit(image, sourceExtent: extent, canvas: canvasRect)
                    var composed = foreground.composited(over: bg).cropped(to: canvasRect)
                    composed = applyTextOverlays(
                        composed,
                        canvas: canvasRect,
                        time: t,
                        overlays: textOverlays
                    )
                    if let chapterRenderer,
                       let chapterImage = chapterRenderer.overlay(at: t.seconds) {
                        composed = chapterImage.composited(over: composed).cropped(to: canvasRect)
                    }
                    request.finish(with: composed, context: nil)
                } else {
                    image = image.cropped(to: extent)
                    image = applyTextOverlays(
                        image,
                        canvas: extent,
                        time: t,
                        overlays: textOverlays
                    )
                    if let chapterRenderer,
                       let chapterImage = chapterRenderer.overlay(at: t.seconds) {
                        image = chapterImage.composited(over: image).cropped(to: extent)
                    }
                    request.finish(with: image, context: nil)
                }
            }
        )
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        if let canvas = exportCanvas {
            vc.renderSize = canvas.renderSize
        }
        return vc
    }

    /// Scale the source image to fit inside the canvas while
    /// preserving aspect, centred. Output lives in the canvas's
    /// coordinate space so it can be composited directly over a
    /// background of the same size.
    static func aspectFit(_ image: CIImage, sourceExtent: CGRect, canvas: CGRect) -> CIImage {
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return image }
        let scale = min(canvas.width / sourceExtent.width, canvas.height / sourceExtent.height)
        guard scale > 0, scale.isFinite else { return image }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let s = scaled.extent
        let tx = canvas.midX - s.midX
        let ty = canvas.midY - s.midY
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }

    /// Produce a canvas-sized CIImage to sit behind the aspect-fit
    /// source. `.color` uses a constant generator; `.blur` aspect-
    /// fills the source into the canvas and applies a Gaussian blur.
    static func makeBackground(
        source: CIImage,
        sourceExtent: CGRect,
        canvas: CGRect,
        style: ProjectDocument.BackgroundStyle
    ) -> CIImage {
        switch style {
        case .color(let c):
            let color = CIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
            let gen = CIFilter(name: "CIConstantColorGenerator")!
            gen.setValue(color, forKey: kCIInputColorKey)
            return (gen.outputImage ?? CIImage(color: color)).cropped(to: canvas)
        case .blur:
            // Aspect-fill: scale uniformly so the smaller canvas
            // dimension is fully covered; source overflow is cropped.
            guard sourceExtent.width > 0, sourceExtent.height > 0 else {
                return CIImage(color: .black).cropped(to: canvas)
            }
            let scale = max(canvas.width / sourceExtent.width, canvas.height / sourceExtent.height)
            let filled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let f = filled.extent
            let tx = canvas.midX - f.midX
            let ty = canvas.midY - f.midY
            let centred = filled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
            let blur = CIFilter(name: "CIGaussianBlur")!
            blur.setValue(centred.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(28.0, forKey: kCIInputRadiusKey)
            let darken = CIFilter(name: "CIColorMatrix")!
            darken.setValue(blur.outputImage ?? centred, forKey: kCIInputImageKey)
            let mul: CGFloat = 0.75
            darken.setValue(CIVector(x: mul, y: 0, z: 0, w: 0), forKey: "inputRVector")
            darken.setValue(CIVector(x: 0, y: mul, z: 0, w: 0), forKey: "inputGVector")
            darken.setValue(CIVector(x: 0, y: 0, z: mul, w: 0), forKey: "inputBVector")
            return (darken.outputImage ?? centred).cropped(to: canvas)
        }
    }

    /// Convert an AspectRatio into a 1920-long-side CGSize suitable as
    /// an AVMutableVideoComposition renderSize. Even dimensions only
    /// (some encoders reject odd widths/heights).
    static func exportRenderSize(for aspect: ProjectDocument.AspectRatio, maxLongSide: CGFloat = 1920) -> CGSize {
        let maxDim = maxLongSide
        let r = aspect.ratio
        var w: CGFloat
        var h: CGFloat
        if r >= 1 {
            w = maxDim
            h = maxDim / r
        } else {
            h = maxDim
            w = maxDim * r
        }
        w = (w.rounded() / 2).rounded() * 2
        h = (h.rounded() / 2).rounded() * 2
        return CGSize(width: max(2, w), height: max(2, h))
    }

    static func needsEffect(_ e: SegmentEffects) -> Bool {
        abs(e.brightness) > 0.001
            || abs(e.contrast - 1.0) > 0.001
            || abs(e.saturation - 1.0) > 0.001
            || e.flipHorizontal
            || e.flipVertical
            || (e.rotation % 360) != 0
    }

    static func applyColor(_ image: CIImage, effects: SegmentEffects) -> CIImage {
        guard let f = CIFilter(name: "CIColorControls") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(effects.brightness, forKey: kCIInputBrightnessKey)
        f.setValue(effects.contrast, forKey: kCIInputContrastKey)
        f.setValue(effects.saturation, forKey: kCIInputSaturationKey)
        return f.outputImage ?? image
    }

    /// Dim the frame toward black during the plan's fade windows.
    /// `factor` == 1 → untouched; `factor` == 0 → full black. Scales
    /// rgb via CIColorMatrix and leaves alpha at 1 so downstream
    /// compositing (background letterbox, text overlays) still sees
    /// an opaque frame that happens to be near-black.
    static func applyTransitionFade(
        _ image: CIImage,
        plan: SegmentVisual,
        time: CMTime,
        extent: CGRect
    ) -> CIImage {
        let t = time.seconds
        let segStart = plan.composedRange.start.seconds
        let segEnd = segStart + plan.composedRange.duration.seconds
        var factor: Double = 1.0
        if plan.fadeInSeconds > 0 {
            let dt = t - segStart
            if dt < plan.fadeInSeconds {
                factor = min(factor, max(0, dt / plan.fadeInSeconds))
            }
        }
        if plan.fadeOutSeconds > 0 {
            let dt = segEnd - t
            if dt < plan.fadeOutSeconds {
                factor = min(factor, max(0, dt / plan.fadeOutSeconds))
            }
        }
        if factor >= 0.999 { return image }
        guard let f = CIFilter(name: "CIColorMatrix") else { return image }
        let v = CGFloat(factor)
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: v, y: 0, z: 0, w: 0), forKey: "inputRVector")
        f.setValue(CIVector(x: 0, y: v, z: 0, w: 0), forKey: "inputGVector")
        f.setValue(CIVector(x: 0, y: 0, z: v, w: 0), forKey: "inputBVector")
        f.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        f.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        return f.outputImage ?? image
    }

    static func applyFlip(_ image: CIImage, effects: SegmentEffects, extent: CGRect) -> CIImage {
        var out = image
        if effects.flipHorizontal {
            var t = CGAffineTransform(scaleX: -1, y: 1)
            t = t.translatedBy(x: -extent.width, y: 0)
            out = out.transformed(by: t)
        }
        if effects.flipVertical {
            var t = CGAffineTransform(scaleX: 1, y: -1)
            t = t.translatedBy(x: 0, y: -extent.height)
            out = out.transformed(by: t)
        }
        return out
    }

    /// Rotate the image in 90° increments around its centre, then
    /// scale-to-fit back into the original `extent` (preserving
    /// aspect, letterboxing with transparent bars if necessary).
    /// `extent` is treated as the target frame — the same size
    /// AVFoundation expects us to finish with.
    static func applyRotation(_ image: CIImage, effects: SegmentEffects, extent: CGRect) -> CIImage {
        let deg = ((effects.rotation % 360) + 360) % 360
        guard deg != 0 else { return image }

        let cx = extent.midX
        let cy = extent.midY
        let radians = CGFloat(deg) * .pi / 180.0

        // Rotate around the image's current centre.
        var t = CGAffineTransform(translationX: -cx, y: -cy)
        t = t.concatenating(CGAffineTransform(rotationAngle: radians))
        t = t.concatenating(CGAffineTransform(translationX: cx, y: cy))
        let rotated = image.transformed(by: t)

        // After a 90°/270° rotation the bounding box is swapped
        // (W↔H). Scale uniformly so the longer side fits the target
        // frame, keeping the image centred.
        let rExtent = rotated.extent
        guard rExtent.width > 0, rExtent.height > 0 else { return rotated }
        let scale = min(extent.width / rExtent.width, extent.height / rExtent.height)
        guard scale > 0, scale.isFinite else { return rotated }

        var s = CGAffineTransform(translationX: -cx, y: -cy)
        s = s.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        s = s.concatenating(CGAffineTransform(translationX: cx, y: cy))
        return rotated.transformed(by: s)
    }

    /// Apply an iOS-only visual preset CIFilter chain. Each branch
    /// configures the filter to read the full source extent so the
    /// output stays framed inside AVFoundation's expected rect.
    static func applyVisualPreset(
        _ image: CIImage,
        preset: ProjectDocument.VisualEffectPreset,
        extent: CGRect
    ) -> CIImage {
        let center = CIVector(x: extent.midX, y: extent.midY)
        switch preset {
        case .none:
            return image
        case .pixellate:
            guard let f = CIFilter(name: "CIPixellate") else { return image }
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(center, forKey: kCIInputCenterKey)
            f.setValue(max(8, min(extent.width, extent.height) / 48), forKey: kCIInputScaleKey)
            return f.outputImage ?? image
        case .bloom:
            guard let f = CIFilter(name: "CIBloom") else { return image }
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(8.0, forKey: kCIInputRadiusKey)
            f.setValue(1.2, forKey: kCIInputIntensityKey)
            return f.outputImage ?? image
        case .vignette:
            guard let f = CIFilter(name: "CIVignette") else { return image }
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(2.0, forKey: kCIInputIntensityKey)
            f.setValue(2.0, forKey: kCIInputRadiusKey)
            return f.outputImage ?? image
        case .sepia:
            guard let f = CIFilter(name: "CISepiaTone") else { return image }
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(0.85, forKey: kCIInputIntensityKey)
            return f.outputImage ?? image
        case .noir:
            guard let f = CIFilter(name: "CIPhotoEffectNoir") else { return image }
            f.setValue(image, forKey: kCIInputImageKey)
            return f.outputImage ?? image
        case .chrome:
            guard let f = CIFilter(name: "CIPhotoEffectChrome") else { return image }
            f.setValue(image, forKey: kCIInputImageKey)
            return f.outputImage ?? image
        case .comic:
            guard let f = CIFilter(name: "CIComicEffect") else { return image }
            f.setValue(image, forKey: kCIInputImageKey)
            return f.outputImage ?? image
        case .thermal:
            guard let f = CIFilter(name: "CIThermal") else { return image }
            f.setValue(image, forKey: kCIInputImageKey)
            return f.outputImage ?? image
        }
    }
}

// MARK: - Text overlays

extension IOSCompositionBuilder {

    /// Composite every text overlay whose composed-time window
    /// contains `time` on top of `image`. Each overlay is rasterised
    /// through UIKit to a CGImage, converted to CIImage, then
    /// positioned via a CGAffineTransform before being composited.
    ///
    /// `canvas` is the rect `image` is expressed in (origin at 0,
    /// extent in pixels). `positionX` / `positionY` are normalized 0…1
    /// with origin bottom-left to match Core Image's coordinate space.
    static func applyTextOverlays(
        _ image: CIImage,
        canvas: CGRect,
        time: CMTime,
        overlays: [IOSSessionState.TextOverlay]
    ) -> CIImage {
        guard !overlays.isEmpty, canvas.width > 0, canvas.height > 0 else { return image }
        let t = time.seconds
        var composed = image
        for o in overlays {
            guard t >= o.startSeconds, t <= o.endSeconds else { continue }
            guard let rendered = rasterizeText(o, canvas: canvas) else { continue }
            let cx = canvas.minX + CGFloat(o.positionX) * canvas.width
            let cy = canvas.minY + CGFloat(o.positionY) * canvas.height
            let tx = cx - rendered.extent.width / 2
            let ty = cy - rendered.extent.height / 2
            let placed = rendered.transformed(by: CGAffineTransform(translationX: tx, y: ty))
            composed = placed.composited(over: composed)
        }
        return composed
    }

    private static func rasterizeText(
        _ overlay: IOSSessionState.TextOverlay,
        canvas: CGRect
    ) -> CIImage? {
        let shortSide = min(canvas.width, canvas.height)
        let pointSize = max(12, shortSide * CGFloat(overlay.fontSizeRel))
        let font = resolveFont(name: overlay.fontName,
                               italic: overlay.italic ?? false,
                               size: pointSize)
        let color = UIColor(
            red: CGFloat(overlay.colorR),
            green: CGFloat(overlay.colorG),
            blue: CGFloat(overlay.colorB),
            alpha: 1.0
        )
        let stroked = overlay.strokeEnabled ?? true
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(stroked ? 0.85 : 0.55)
        shadow.shadowBlurRadius = pointSize * (stroked ? 0.18 : 0.24)
        shadow.shadowOffset = .zero
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .shadow: shadow
        ]
        if stroked {
            attrs[.strokeColor] = UIColor.black
            attrs[.strokeWidth] = -3.0
        }
        let text = overlay.text as NSString
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = pointSize * 0.4
        let pixelSize = CGSize(width: ceil(size.width + pad * 2),
                               height: ceil(size.height + pad * 2))
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        let ui = renderer.image { _ in
            text.draw(at: CGPoint(x: pad, y: pad), withAttributes: attrs)
        }
        guard let cg = ui.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        return ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -ci.extent.height))
    }

    /// Resolve a PostScript font name to an actual UIFont. Falls back
    /// to bold system font if the name isn't installed (e.g. JSON
    /// from another device referenced a font we don't ship). When
    /// `italic` is requested, applies the trait descriptor; if the
    /// font has no italic variant, leaves it upright rather than
    /// synthesising a skew.
    private static func resolveFont(name: String?, italic: Bool, size: CGFloat) -> UIFont {
        let base: UIFont
        if let name, let custom = UIFont(name: name, size: size) {
            base = custom
        } else {
            base = UIFont.systemFont(ofSize: size, weight: .bold)
        }
        guard italic else { return base }
        if let desc = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) {
            return UIFont(descriptor: desc, size: size)
        }
        return base
    }
}
