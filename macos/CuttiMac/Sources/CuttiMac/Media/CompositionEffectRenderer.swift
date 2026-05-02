import CoreImage
import Foundation

/// Shared effect-application logic used by both video-compositor backends.
///
/// The default `applyingCIFiltersWithHandler` path and the custom
/// `PiPVideoCompositor` both need to apply per-segment CIColorControls,
/// rotation/flip transforms, and subtitle/chapter burn-ins to each frame.
/// Keeping this in one place guarantees pixel-identical output across
/// backends — a regression here would be extremely hard to spot in
/// exports.
enum CompositionEffectRenderer {

    /// Apply the full effect stack to `image` for frame-time `currentTime`.
    ///
    /// - Parameters:
    ///   - image: input frame (already-composited in the CIFilter-handler
    ///     backend; primary-only background in the custom-compositor
    ///     backend — PiP overlays are added by the caller afterwards).
    ///   - currentTime: composition time in seconds (for finding the
    ///     owning `ComposedSegmentInfo` and feeding the burn-in renderers).
    ///   - composedInfos: primary segment effect metadata, sorted by
    ///     composed time. Lookup is O(n) which is fine for <1000 segments.
    ///   - renderSize: output canvas size. Not currently used by this
    ///     function directly but reserved for future effects (e.g. a
    ///     size-relative vignette).
    ///   - subtitleRenderer: optional. When present, emits a subtitle
    ///     overlay image for `currentTime` and composites it on top.
    ///   - chapterRenderer: optional. Same contract as `subtitleRenderer`
    ///     but stacks above subtitles.
    static func applyEffects(
        to image: CIImage,
        at currentTime: Double,
        composedInfos: [ComposedSegmentInfo],
        renderSize: CGSize,
        subtitleRenderer: SubtitleBurnInRenderer?,
        chapterRenderer: ChapterBarBurnInRenderer?
    ) -> CIImage {
        var image = image

        let info = composedInfos.first {
            currentTime >= $0.composedStart && currentTime < $0.composedEnd
        }
        let effects = info?.effects ?? .default

        if effects.hasColorAdjustment {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(NSNumber(value: effects.brightness), forKey: kCIInputBrightnessKey)
                filter.setValue(NSNumber(value: effects.contrast), forKey: kCIInputContrastKey)
                filter.setValue(NSNumber(value: effects.saturation), forKey: kCIInputSaturationKey)
                if let output = filter.outputImage {
                    image = output
                }
            }
        }

        if effects.hasTransform {
            let extent = image.extent
            let cx = extent.midX
            let cy = extent.midY
            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: cx, y: cy)
            if effects.rotation != 0 {
                let radians = CGFloat(effects.rotation) * .pi / 180
                transform = transform.rotated(by: radians)
            }
            if effects.flipHorizontal {
                transform = transform.scaledBy(x: -1, y: 1)
            }
            if effects.flipVertical {
                transform = transform.scaledBy(x: 1, y: -1)
            }
            transform = transform.translatedBy(x: -cx, y: -cy)
            image = image.transformed(by: transform)

            let transformedExtent = image.extent
            if transformedExtent.origin != .zero {
                image = image.transformed(by: CGAffineTransform(
                    translationX: -transformedExtent.origin.x,
                    y: -transformedExtent.origin.y
                ))
            }
        }

        if let subtitleRenderer,
           let overlay = subtitleRenderer.overlay(at: currentTime) {
            image = overlay.composited(over: image)
        }

        if let chapterRenderer,
           let overlay = chapterRenderer.overlay(at: currentTime) {
            image = overlay.composited(over: image)
        }

        _ = renderSize // reserved for future size-dependent effects
        return image
    }
}
