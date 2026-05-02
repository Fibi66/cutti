import AVFoundation
import CoreImage
import UIKit
import CuttiKit

/// Custom `AVVideoCompositing` for iOS preview of timelines that contain
/// picture-in-picture overlays.
///
/// iOS's default `applyingCIFiltersWithHandler` path only ever sees one
/// merged source frame and can't drive multi-track PiP. When the
/// composition contains an overlay track carrying a `pipLayout` (or a
/// `freeTransform`) we swap in this compositor, which:
///
/// 1. reads the primary track's frame as the background canvas,
/// 2. re-applies primary-segment effects / fades / text overlays using
///    the same helpers the CIFilter path uses (so non-PiP visuals stay
///    pixel-identical across backends), and
/// 3. composites each active overlay on top, applying either
///    `freeTransform` (affine + opacity) or `pipLayout` (corner anchor,
///    shape mask) via shared `PiPGeometry`.
///
/// Scope: preview only for now. The export pipeline
/// (`IOSExportService`) still goes through the single-track builder; a
/// follow-up unifies export. This comment should shrink when that lands.
final class IOSPiPCompositor: NSObject, AVVideoCompositing {

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let renderQueue = DispatchQueue(label: "cutti.ios.pip.compositor", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "cutti.ios.pip.compositor.state", qos: .userInitiated)
    private var renderContext: AVVideoCompositionRenderContext?

    override init() {
        super.init()
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        stateQueue.sync { self.renderContext = newRenderContext }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            autoreleasepool {
                guard let self,
                      let instruction = request.videoCompositionInstruction as? IOSPiPInstruction,
                      let ctx = self.stateQueue.sync(execute: { self.renderContext })
                else {
                    request.finish(with: NSError(domain: "IOSPiPCompositor", code: 1))
                    return
                }

                let canvas = CGRect(origin: .zero, size: ctx.size)

                // Background = primary frame (or black if primary is
                // inactive for this slice of the timeline).
                var primaryImage: CIImage
                if let primaryID = instruction.primaryTrackID,
                   let buf = request.sourceFrame(byTrackID: primaryID) {
                    primaryImage = CIImage(cvPixelBuffer: buf)
                } else {
                    primaryImage = CIImage(color: .black).cropped(to: canvas)
                }
                let primaryExtent = primaryImage.extent

                // Re-apply primary-segment effects using the SAME helpers
                // the CIFilter-handler path uses, so toggling a PiP on
                // doesn't change the primary's look.
                let t = request.compositionTime
                if let plan = instruction.primaryPlans.first(where: {
                    CMTimeRangeContainsTime($0.composedRange, time: t)
                }) {
                    if IOSCompositionBuilder.needsEffect(plan.effects) {
                        primaryImage = IOSCompositionBuilder.applyColor(primaryImage, effects: plan.effects)
                        primaryImage = IOSCompositionBuilder.applyFlip(primaryImage, effects: plan.effects, extent: primaryExtent)
                        primaryImage = IOSCompositionBuilder.applyRotation(primaryImage, effects: plan.effects, extent: primaryExtent)
                    }
                    if plan.visualPreset != .none {
                        primaryImage = IOSCompositionBuilder.applyVisualPreset(
                            primaryImage,
                            preset: plan.visualPreset,
                            extent: primaryExtent
                        )
                    }
                    if plan.fadeInSeconds > 0 || plan.fadeOutSeconds > 0 {
                        primaryImage = IOSCompositionBuilder.applyTransitionFade(
                            primaryImage,
                            plan: plan,
                            time: t,
                            extent: primaryExtent
                        )
                    }
                }

                // In export mode aspect-fit the primary into the target
                // canvas and fill the letterbox with the project's
                // background style (blur / solid color). In preview mode
                // the primary already fills the canvas so no letterbox.
                var composed: CIImage
                if let exportCanvas = instruction.exportCanvas {
                    let bg = IOSCompositionBuilder.makeBackground(
                        source: primaryImage,
                        sourceExtent: primaryExtent,
                        canvas: canvas,
                        style: exportCanvas.background
                    )
                    let foreground = IOSCompositionBuilder.aspectFit(
                        primaryImage,
                        sourceExtent: primaryExtent,
                        canvas: canvas
                    )
                    composed = foreground.composited(over: bg).cropped(to: canvas)
                } else {
                    composed = primaryImage
                }

                // Composite every active overlay on top of primary.
                for overlay in instruction.overlays {
                    guard CMTimeRangeContainsTime(overlay.composedRange, time: t) else { continue }
                    guard let buf = request.sourceFrame(byTrackID: overlay.trackID) else { continue }
                    let overlayImage = CIImage(cvPixelBuffer: buf)
                    composed = Self.layerOverlay(
                        background: composed,
                        overlay: overlayImage,
                        pipLayout: overlay.pipLayout,
                        freeTransform: overlay.freeTransform,
                        canvas: canvas
                    )
                }

                // Finally, draw text overlays on the merged frame so
                // captions sit on top of PiP (matches macOS behavior).
                composed = IOSCompositionBuilder.applyTextOverlays(
                    composed,
                    canvas: canvas,
                    time: t,
                    overlays: instruction.textOverlays
                )

                if let burn = instruction.chapterBurnIn,
                   !burn.chapters.isEmpty {
                    let renderer = ChapterBarBurnInRenderer(
                        chapters: burn.chapters,
                        totalSeconds: burn.totalSeconds,
                        renderSize: canvas.size,
                        style: burn.style
                    )
                    if let chapterImage = renderer.overlay(at: t.seconds) {
                        composed = chapterImage.composited(over: composed).cropped(to: canvas)
                    }
                }

                guard let outBuffer = ctx.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "IOSPiPCompositor", code: 2))
                    return
                }
                self.ciContext.render(composed, to: outBuffer)
                request.finish(withComposedVideoFrame: outBuffer)
            }
        }
    }

    // MARK: - Compositing primitives

    /// Layer one overlay frame over the background canvas, honoring the
    /// overlay's `freeTransform` (affine + opacity) or `pipLayout`
    /// (corner anchor + shape mask). If both are nil, the overlay
    /// fully covers the background (legacy B-roll behaviour).
    private static func layerOverlay(
        background: CIImage,
        overlay: CIImage,
        pipLayout: PiPLayout?,
        freeTransform: FreeTransform?,
        canvas: CGRect
    ) -> CIImage {
        if let ft = freeTransform {
            return compositeFreeTransform(
                background: background,
                overlay: overlay,
                transform: ft,
                canvas: canvas
            )
        }
        if let layout = pipLayout {
            return compositePiP(
                background: background,
                overlay: overlay,
                layout: layout,
                canvas: canvas
            )
        }
        // No layout metadata: aspect-fill the overlay over the canvas.
        return overlay.cropped(to: canvas).composited(over: background)
    }

    /// PiP composite: shrink the overlay to the layout's corner-anchored
    /// rect, apply a shape mask (circle / rounded / square), then
    /// composite over the background.
    private static func compositePiP(
        background: CIImage,
        overlay: CIImage,
        layout: PiPLayout,
        canvas: CGRect
    ) -> CIImage {
        let srcExtent = overlay.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return background }
        let geometry = PiPGeometry.compute(
            layout: layout,
            canvasSize: canvas.size,
            sourceFrameSize: srcExtent.size
        )
        // PiPGeometry returns a rect in top-left origin UI space. CI
        // uses bottom-left. Flip originY against canvas height.
        let flippedY = canvas.height - geometry.rect.origin.y - geometry.rect.height
        let targetRect = CGRect(
            x: geometry.rect.origin.x,
            y: flippedY,
            width: geometry.rect.width,
            height: geometry.rect.height
        )

        // Center-crop the source to a square so .circle / .roundedSquare
        // don't stretch a 16:9 overlay into a squashed pill.
        let side = min(srcExtent.width, srcExtent.height)
        let cropOrigin = CGPoint(
            x: srcExtent.midX - side / 2,
            y: srcExtent.midY - side / 2
        )
        let cropped = overlay.cropped(to: CGRect(origin: cropOrigin, size: CGSize(width: side, height: side)))

        // Scale + translate the cropped square into targetRect.
        let scaleX = targetRect.width / side
        let scaleY = targetRect.height / side
        var placed = cropped
            .transformed(by: CGAffineTransform(translationX: -cropOrigin.x, y: -cropOrigin.y))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: targetRect.origin.x, y: targetRect.origin.y))

        // Apply shape mask. Square needs no mask.
        if layout.shape != .square {
            let maskRect = targetRect
            let mask = makeShapeMask(shape: layout.shape, rect: maskRect, cornerRadius: geometry.cornerRadius)
            placed = placed.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: canvas),
                kCIInputMaskImageKey: mask
            ])
        }

        return placed.composited(over: background).cropped(to: canvas)
    }

    /// FreeTransform composite: apply opacity + affine (position/
    /// scale/rotation) via the shared `FreeTransformGeometry` helper,
    /// then composite over the background.
    private static func compositeFreeTransform(
        background: CIImage,
        overlay: CIImage,
        transform: FreeTransform,
        canvas: CGRect
    ) -> CIImage {
        let srcExtent = overlay.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return background }
        let ciTransform = FreeTransformGeometry.ciTransform(
            sourceSize: srcExtent.size,
            canvasSize: canvas.size,
            transform: transform
        )
        var placed = overlay.transformed(by: ciTransform)
        if transform.opacity < 0.999 {
            placed = placed.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(transform.opacity))
            ])
        }
        return placed.composited(over: background).cropped(to: canvas)
    }

    /// Rasterise a filled shape into a CIImage the size of `canvas`
    /// (rest transparent). Used as the alpha mask in `compositePiP`.
    private static func makeShapeMask(
        shape: PiPLayout.Shape,
        rect: CGRect,
        cornerRadius: CGFloat
    ) -> CIImage {
        // UIKit-space canvas (top-left) — we'll flip Y by rendering into
        // a CGContext and converting; easier to use CGContext directly.
        // The rect we receive is already in CI-space (bottom-left), so
        // just paint into a CGBitmapContext matching canvas size.
        let canvasSize = CGSize(
            width: rect.maxX + 1,
            height: rect.maxY + 1
        )
        // Expand canvas to the full extent so the mask aligns with the
        // background image's extent. Use the enclosing rect of canvas
        // + mask rect.
        let w = Int(ceil(max(canvasSize.width, rect.maxX)))
        let h = Int(ceil(max(canvasSize.height, rect.maxY)))
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: max(1, w),
            height: max(1, h),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return CIImage(color: .white).cropped(to: rect)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        switch shape {
        case .circle:
            ctx.fillEllipse(in: rect)
        case .roundedSquare:
            let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        case .square:
            ctx.fill(rect)
        }
        guard let cgImage = ctx.makeImage() else {
            return CIImage(color: .white).cropped(to: rect)
        }
        return CIImage(cgImage: cgImage)
    }
}

/// One primary-segment plan carried alongside overlay plans inside an
/// `IOSPiPInstruction`. Aliased to `IOSCompositionBuilder.SegmentVisual`
/// so the compositor can pass plans directly to the shared effect
/// helpers (applyTransitionFade etc.) with no adapter copy.
typealias IOSPiPPrimaryPlan = IOSCompositionBuilder.SegmentVisual

/// One overlay plan. The compositor reads the trackID, matches it to
/// the request's source frames, and renders it at its composedRange.
struct IOSPiPOverlayPlan {
    let trackID: CMPersistentTrackID
    let composedRange: CMTimeRange
    let pipLayout: PiPLayout?
    let freeTransform: FreeTransform?
}

/// Full-duration instruction carrying every primary/overlay plan plus
/// text overlays. The compositor runs this same instruction for every
/// frame and picks the right plan by `composedRange` containment.
///
/// Using a single instruction keeps the builder simple (no need to
/// slice time into per-change windows) at the cost of asking AVFoundation
/// to decode every overlay track every frame — acceptable for a
/// small number of overlays in preview; export can split instructions
/// later if needed.
final class IOSPiPInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let primaryTrackID: CMPersistentTrackID?
    let primaryPlans: [IOSPiPPrimaryPlan]
    let overlays: [IOSPiPOverlayPlan]
    let textOverlays: [IOSSessionState.TextOverlay]
    /// When non-nil the compositor aspect-fits the primary into this
    /// canvas and fills the letterbox with `background`. Overlays are
    /// then composited in the canvas's coordinate space. Nil for
    /// preview (uses the natural primary extent).
    let exportCanvas: (renderSize: CGSize, background: ProjectDocument.BackgroundStyle)?
    /// Optional chapter progress-bar burn-in. Built once and rendered
    /// at every frame — cheap because the renderer caches its bitmap
    /// per-time only (no shared state).
    let chapterBurnIn: IOSCompositionBuilder.ChapterBurnIn?

    init(
        timeRange: CMTimeRange,
        primaryTrackID: CMPersistentTrackID?,
        primaryPlans: [IOSPiPPrimaryPlan],
        overlays: [IOSPiPOverlayPlan],
        textOverlays: [IOSSessionState.TextOverlay],
        exportCanvas: (renderSize: CGSize, background: ProjectDocument.BackgroundStyle)? = nil,
        chapterBurnIn: IOSCompositionBuilder.ChapterBurnIn? = nil
    ) {
        self.timeRange = timeRange
        self.primaryTrackID = primaryTrackID
        self.primaryPlans = primaryPlans
        self.overlays = overlays
        self.textOverlays = textOverlays
        self.exportCanvas = exportCanvas
        self.chapterBurnIn = chapterBurnIn
        var ids: [NSValue] = []
        if let p = primaryTrackID { ids.append(NSNumber(value: p)) }
        for o in overlays { ids.append(NSNumber(value: o.trackID)) }
        self.requiredSourceTrackIDs = ids.isEmpty ? nil : ids
        super.init()
    }
}
