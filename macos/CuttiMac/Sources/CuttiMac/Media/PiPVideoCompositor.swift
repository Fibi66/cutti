import AVFoundation
import CoreImage
import ImageIO
import CuttiKit

/// Custom `AVVideoCompositing` that handles Picture-in-Picture overlays.
///
/// **Dual-backend rationale**: the existing `applyingCIFiltersWithHandler`
/// path produces a pre-merged source image per frame — fine for projects
/// where overlays fully cover V1, but insufficient once PiP needs per-track
/// access to apply transform + shape mask. This compositor is engaged only
/// when the composition contains at least one overlay segment with a
/// `pipLayout` (see `CompositionBuilder.build`). Non-PiP timelines continue
/// to use the CIFilter-handler path unchanged.
///
/// Contract with `AVVideoComposition`:
/// - `videoComposition.instructions` must be `PiPCompositionInstruction`s
///   covering `[0, totalDuration)`, each carrying the set of active track
///   IDs + layouts for that time range.
/// - The PRIMARY track's ID is always the first element of
///   `AVMutableVideoCompositionInstruction.requiredSourceTrackIDs` (this
///   compositor treats the first required ID as the background).
/// - Overlay tracks in the instruction are drawn on top of primary in the
///   order they appear; overlays with a non-nil `pipLayout` get scaled +
///   masked; overlays with a nil layout fully cover primary (legacy B-roll).
///
/// Effects (CIColorControls + rotation/flip) on the primary segment are
/// still applied; the shared `CompositionEffectRenderer` is used so both
/// backends produce pixel-identical output for non-PiP segments.
final class PiPVideoCompositor: NSObject, AVVideoCompositing {

    // MARK: - AVVideoCompositing conformance

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    private var renderContext: AVVideoCompositionRenderContext?
    private let ciContext: CIContext
    private let renderQueue = DispatchQueue(label: "cutti.pip.compositor", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "cutti.pip.compositor.state", qos: .userInitiated)
    /// Loaded image overlays keyed by source URL. The compositor is the
    /// natural home for this cache: images for a given composition are
    /// drawn repeatedly across many frames, and the cache lives for the
    /// lifetime of the compositor (one per AVPlayer / AVAssetWriter).
    /// Access is serialized through `renderQueue` which is the only
    /// queue that ever touches it.
    private var imageCache: [URL: CIImage] = [:]
    /// Incremented whenever AVFoundation invalidates queued requests
    /// (seek/scrub/rate changes). Requests capture the generation at
    /// enqueue time and bail if they become stale before rendering.
    private var cancelGeneration: UInt64 = 0

    override init() {
        // Default CI context — metal-backed where available. We don't
        // need color-managed pipelines because final output goes through
        // AVAssetWriter which re-applies color tags.
        self.ciContext = CIContext(options: [.cacheIntermediates: false])
        super.init()
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        stateQueue.sync {
            self.renderContext = newRenderContext
        }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let requestGeneration = currentCancelGeneration()
        renderQueue.async { [weak self] in
            autoreleasepool {
                guard let self else {
                    request.finishCancelledRequest()
                    return
                }
                guard !self.isCancelled(requestGeneration) else {
                    request.finishCancelledRequest()
                    return
                }
                guard let instruction = request.videoCompositionInstruction as? PiPCompositionInstruction else {
                    // We only ever install PiPCompositionInstructions, but be
                    // defensive: pass-through on anything else would crash.
                    request.finish(with: NSError(domain: "PiPCompositor", code: 2))
                    return
                }
                guard let ctx = self.currentRenderContext() else {
                    request.finish(with: NSError(domain: "PiPCompositor", code: 1))
                    return
                }
                guard let outBuffer = ctx.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "PiPCompositor", code: 3))
                    return
                }

                let renderSize = ctx.size

                // Start with either the primary frame or a black canvas if
                // primary isn't active right now (e.g. during an overlay-only
                // time range — rare but possible).
                var composed: CIImage = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize))
                if let primaryID = instruction.primaryTrackID,
                   let primaryBuf = request.sourceFrame(byTrackID: primaryID) {
                    composed = CIImage(cvPixelBuffer: primaryBuf)
                }

                // Apply shared effects pipeline (color + transform + burn-ins)
                // to primary — same logic as the CIFilter-handler backend.
                composed = CompositionEffectRenderer.applyEffects(
                    to: composed,
                    at: request.compositionTime.seconds,
                    composedInfos: instruction.composedInfos,
                    renderSize: renderSize,
                    subtitleRenderer: instruction.subtitleRenderer,
                    chapterRenderer: instruction.chapterRenderer
                )

                // Layer overlays top-to-bottom. Overlays with pipLayout get
                // scaled + masked; overlays without a layout fully cover
                // primary (legacy B-roll behavior).
                for overlay in instruction.overlays {
                    guard !self.isCancelled(requestGeneration) else {
                        request.finishCancelledRequest()
                        return
                    }

                    let overlayImage: CIImage
                    switch overlay.source {
                    case let .track(trackID):
                        guard let buf = request.sourceFrame(byTrackID: trackID) else { continue }
                        overlayImage = CIImage(cvPixelBuffer: buf)
                    case let .image(url):
                        guard let img = self.loadImageOverlay(url: url) else {
                            print("🔴 PiPCompositor: loadImageOverlay returned nil for \(url.path) (t=\(request.compositionTime.seconds)s)")
                            continue
                        }
                        overlayImage = img
                    }

                    // FreeTransform beats PiP layout when both are present.
                    // Free transform is a flat affine+opacity pipeline, no
                    // shape mask; PiP is a corner-anchored preset.
                    if let ft = overlay.freeTransform {
                        composed = Self.compositeFreeTransform(
                            background: composed,
                            overlay: overlayImage,
                            transform: ft,
                            canvasSize: renderSize
                        )
                    } else if let layout = overlay.pipLayout {
                        composed = Self.compositePiP(
                            background: composed,
                            overlay: overlayImage,
                            layout: layout,
                            canvasSize: renderSize
                        )
                    } else {
                        // Full-cover: aspect-fit image overlays (so they don't
                        // distort to canvas aspect); track overlays arrive
                        // pre-sized and just composite on top.
                        switch overlay.source {
                        case .track:
                            composed = overlayImage.composited(over: composed)
                        case .image:
                            composed = Self.compositeFullCoverImage(
                                background: composed,
                                overlay: overlayImage,
                                canvasSize: renderSize
                            )
                        }
                    }
                }

                guard !self.isCancelled(requestGeneration) else {
                    request.finishCancelledRequest()
                    return
                }

                // Flatten to the output buffer.
                self.ciContext.render(
                    composed,
                    to: outBuffer,
                    bounds: CGRect(origin: .zero, size: renderSize),
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )

                guard !self.isCancelled(requestGeneration) else {
                    request.finishCancelledRequest()
                    return
                }
                request.finish(withComposedVideoFrame: outBuffer)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        stateQueue.sync {
            cancelGeneration &+= 1
        }
    }

    private func currentRenderContext() -> AVVideoCompositionRenderContext? {
        stateQueue.sync { renderContext }
    }

    private func currentCancelGeneration() -> UInt64 {
        stateQueue.sync { cancelGeneration }
    }

    private func isCancelled(_ requestGeneration: UInt64) -> Bool {
        stateQueue.sync { cancelGeneration != requestGeneration }
    }

    // MARK: - Image overlay loading

    /// Load an image overlay from disk, normalize EXIF orientation, and
    /// cache the result. Returns nil if the URL isn't decodable — caller
    /// skips the overlay for that frame.
    ///
    /// Must only be called from `renderQueue` so the cache stays
    /// single-threaded.
    private func loadImageOverlay(url: URL) -> CIImage? {
        if let cached = imageCache[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let base = CIImage(cgImage: cg)
        // EXIF orientation: JPEGs from phones are commonly stored rotated
        // with an orientation tag. CIImage(cgImage:) ignores it, so we
        // read + apply it explicitly. kCGImagePropertyOrientation values
        // map 1:1 to CGImagePropertyOrientation raw values.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let oriented: CIImage
        if let raw = props?[kCGImagePropertyOrientation] as? UInt32,
           let o = CGImagePropertyOrientation(rawValue: raw) {
            oriented = base.oriented(o)
        } else {
            oriented = base
        }
        imageCache[url] = oriented
        return oriented
    }

    // MARK: - Free-transform compositing

    /// Apply a FreeTransform (position / scale / rotation / opacity)
    /// to an overlay and composite it over the background. Uses the
    /// shared `FreeTransformGeometry.ciTransform` so the unit tests
    /// and the compositor agree on geometry semantics.
    static func compositeFreeTransform(
        background: CIImage,
        overlay: CIImage,
        transform: FreeTransform,
        canvasSize: CGSize
    ) -> CIImage {
        let extent = overlay.extent
        guard extent.width > 0, extent.height > 0 else { return background }
        let matrix = FreeTransformGeometry.ciTransform(
            sourceSize: extent.size,
            canvasSize: canvasSize,
            transform: transform
        )
        var transformed = overlay.transformed(by: matrix)
        // Clamp opacity 0…1 and apply via multiplication in alpha.
        let opacity = max(0.0, min(1.0, transform.opacity))
        if opacity < 0.999 {
            if let f = CIFilter(name: "CIColorMatrix") {
                f.setValue(transformed, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)), forKey: "inputAVector")
                if let out = f.outputImage { transformed = out }
            }
        }
        return transformed.composited(over: background)
    }

    // MARK: - Full-cover image compositing

    /// Aspect-fit the image onto the canvas, then composite over the
    /// background. Used when an image overlay has no `pipLayout` (it
    /// acts like a full-canvas layer but the source rarely matches the
    /// canvas aspect, so fit-with-letterbox is the sensible default).
    static func compositeFullCoverImage(
        background: CIImage,
        overlay: CIImage,
        canvasSize: CGSize
    ) -> CIImage {
        let e = overlay.extent
        guard e.width > 0, e.height > 0 else { return background }
        let scale = min(canvasSize.width / e.width, canvasSize.height / e.height)
        let scaled = overlay.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let s = scaled.extent
        let dx = (canvasSize.width - s.width) / 2 - s.minX
        let dy = (canvasSize.height - s.height) / 2 - s.minY
        let centered = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        // Paint a black canvas first so the aspect-fit letterbox /
        // pillarbox bars read black instead of leaking the background
        // (which for primary-image segments is a hidden filler video).
        let blackCanvas = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvasSize))
        return centered.composited(over: blackCanvas)
    }

    // MARK: - PiP compositing

    /// Composite one PiP overlay onto the background.
    ///
    /// Steps:
    ///   1. Compute geometry (rect + corner radius + scale) from layout.
    ///   2. Scale overlay uniformly so its shorter dimension fills the
    ///      target rect's shorter dimension — center-cropped.
    ///   3. Translate scaled overlay so it sits inside the target rect.
    ///   4. Build a rounded-rect (or circle) mask and blend overlay over
    ///      background through the mask.
    ///   5. Draw optional border stroke on top using a hollow mask.
    static func compositePiP(
        background: CIImage,
        overlay: CIImage,
        layout: PiPLayout,
        canvasSize: CGSize
    ) -> CIImage {
        let overlayExtent = overlay.extent
        guard overlayExtent.width > 0, overlayExtent.height > 0 else { return background }

        let geom = PiPGeometry.compute(
            layout: layout,
            canvasSize: canvasSize,
            sourceFrameSize: overlayExtent.size
        )

        // Center-crop scale: pick the LARGER of width/height fit so the
        // target box is fully covered by the scaled source (Apple's
        // `.scaledToFill()` semantics).
        let fillScale = max(
            geom.rect.width / overlayExtent.width,
            geom.rect.height / overlayExtent.height
        )

        var scaled = overlay.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        // After scaling, recenter the scaled image over the target rect.
        let scaledExtent = scaled.extent
        let dx = geom.rect.midX - scaledExtent.midX
        // AVFoundation / CoreImage uses bottom-left origin; PiPGeometry.rect
        // is top-left. Convert by mirroring Y.
        let flippedRectMinY = canvasSize.height - geom.rect.maxY
        let flippedRectMidY = flippedRectMinY + geom.rect.height / 2
        let dy = flippedRectMidY - scaledExtent.midY
        scaled = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))

        // Clip scaled overlay to the target rect (so the center-crop
        // doesn't bleed outside the box).
        let targetRectBL = CGRect(
            x: geom.rect.minX,
            y: flippedRectMinY,
            width: geom.rect.width,
            height: geom.rect.height
        )
        scaled = scaled.cropped(to: targetRectBL)

        // Build a shape mask (white inside the rounded rect / circle,
        // transparent outside). CIRoundedRectangleGenerator is perfect
        // for both circle and roundedSquare (radius = half-side for
        // circle).
        guard let maskFilter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return scaled.composited(over: background)
        }
        maskFilter.setValue(CIVector(cgRect: targetRectBL), forKey: "inputExtent")
        maskFilter.setValue(geom.cornerRadius, forKey: "inputRadius")
        maskFilter.setValue(CIColor.white, forKey: "inputColor")
        guard let mask = maskFilter.outputImage else {
            return scaled.composited(over: background)
        }

        // Blend overlay over background through the shape mask.
        let blend = CIFilter(name: "CIBlendWithMask")
        blend?.setValue(scaled, forKey: kCIInputImageKey)
        blend?.setValue(background, forKey: kCIInputBackgroundImageKey)
        blend?.setValue(mask, forKey: kCIInputMaskImageKey)
        var result = blend?.outputImage ?? scaled.composited(over: background)

        // Optional border: stroke a ring by subtracting an inset mask
        // from the full mask, color it, and composite on top.
        if geom.borderWidth > 0.5 {
            let borderColor: CIColor = {
                if let hex = layout.borderColorHex, let c = CIColor(hex: hex) {
                    return c
                }
                return CIColor.white
            }()
            if let ringFilter = CIFilter(name: "CIRoundedRectangleGenerator") {
                let insetRect = targetRectBL.insetBy(dx: geom.borderWidth, dy: geom.borderWidth)
                ringFilter.setValue(CIVector(cgRect: insetRect), forKey: "inputExtent")
                ringFilter.setValue(max(0, geom.cornerRadius - geom.borderWidth), forKey: "inputRadius")
                ringFilter.setValue(CIColor.white, forKey: "inputColor")
                if let innerMask = ringFilter.outputImage {
                    // Ring mask = outer mask minus inner mask.
                    let subtract = CIFilter(name: "CISubtractBlendMode")
                    subtract?.setValue(mask, forKey: kCIInputImageKey)
                    subtract?.setValue(innerMask, forKey: kCIInputBackgroundImageKey)
                    if let ringMask = subtract?.outputImage {
                        let stroke = CIImage(color: borderColor).cropped(to: targetRectBL)
                        let ringBlend = CIFilter(name: "CIBlendWithMask")
                        ringBlend?.setValue(stroke, forKey: kCIInputImageKey)
                        ringBlend?.setValue(result, forKey: kCIInputBackgroundImageKey)
                        ringBlend?.setValue(ringMask, forKey: kCIInputMaskImageKey)
                        if let bordered = ringBlend?.outputImage {
                            result = bordered
                        }
                    }
                }
            }
        }

        return result
    }
}

// MARK: - Instruction

/// One `AVVideoCompositionInstruction` for the PiP compositor. Each
/// instance covers a single time range; each field documents the fixed
/// state that range represents.
final class PiPCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {

    struct OverlayEntry {
        /// Where this overlay's pixels come from. Track-backed overlays
        /// are driven by AVFoundation's source-frame delivery; image-
        /// backed overlays bypass the AV composition tracks entirely
        /// and synthesize a CIImage on demand (see
        /// `PiPVideoCompositor.imageCache`).
        enum Source {
            case track(CMPersistentTrackID)
            case image(url: URL)
        }
        let source: Source
        /// Nil = full-cover overlay (legacy B-roll behavior).
        let pipLayout: PiPLayout?
        /// Optional free-transform (position/scale/rotation/opacity).
        /// When set, `freeTransform` takes precedence over `pipLayout`.
        let freeTransform: FreeTransform?
    }

    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let primaryTrackID: CMPersistentTrackID?
    let overlays: [OverlayEntry]

    /// Composed-segment metadata for the effect pipeline (shared with
    /// the CIFilter-handler backend). Primary segments only.
    let composedInfos: [ComposedSegmentInfo]
    let subtitleRenderer: SubtitleBurnInRenderer?
    let chapterRenderer: ChapterBarBurnInRenderer?

    init(
        timeRange: CMTimeRange,
        primaryTrackID: CMPersistentTrackID?,
        overlays: [OverlayEntry],
        composedInfos: [ComposedSegmentInfo],
        subtitleRenderer: SubtitleBurnInRenderer?,
        chapterRenderer: ChapterBarBurnInRenderer?
    ) {
        self.timeRange = timeRange
        self.primaryTrackID = primaryTrackID
        self.overlays = overlays
        self.composedInfos = composedInfos
        self.subtitleRenderer = subtitleRenderer
        self.chapterRenderer = chapterRenderer

        var required: [CMPersistentTrackID] = []
        if let p = primaryTrackID { required.append(p) }
        for o in overlays {
            if case let .track(id) = o.source { required.append(id) }
        }
        self.requiredSourceTrackIDs = required.map { NSNumber(value: $0) }

        super.init()
    }
}

// MARK: - CIColor hex helper

private extension CIColor {
    /// Parses "#RRGGBB" or "#RRGGBBAA" hex strings. Returns nil on bad
    /// input rather than crashing — layouts can come from hand-edited
    /// JSON.
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var v: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&v) else { return nil }
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255.0
            g = CGFloat((v >> 16) & 0xFF) / 255.0
            b = CGFloat((v >> 8) & 0xFF) / 255.0
            a = CGFloat(v & 0xFF) / 255.0
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255.0
            g = CGFloat((v >> 8) & 0xFF) / 255.0
            b = CGFloat(v & 0xFF) / 255.0
            a = 1.0
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
