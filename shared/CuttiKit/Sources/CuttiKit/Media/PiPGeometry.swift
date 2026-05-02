import CoreGraphics
import Foundation

/// Pure geometry math for Picture-in-Picture overlay placement.
///
/// Given the canvas `renderSize`, the source overlay frame's `frameSize`,
/// and a `PiPLayout`, this computes where the overlay should render on
/// the canvas (rect, scale factor) and what mask/corner-radius to apply
/// for the shape. All values are in canvas pixels (top-left origin, as
/// used by `CoreImage` / `CGImage`; the compositor converts to AV's
/// bottom-left origin at the end).
///
/// Used by BOTH the SwiftUI preview layer (for live feedback while
/// editing) AND the custom `AVVideoCompositing` renderer (for export),
/// so preview and export stay pixel-identical. Pure, no AVFoundation,
/// no Core Image — trivially unit-testable.
public struct PiPGeometry: Equatable {

    /// The rect on the canvas where the overlay thumbnail should land,
    /// in canvas pixels, top-left origin. Width and height are
    /// post-scale.
    public let rect: CGRect

    /// Scale factor applied to the source frame to reach `rect`.
    /// Derived from `rect.height / sourceFrameHeight`.
    public let scale: CGFloat

    /// Corner radius in canvas pixels. Zero for `.square`; half of
    /// min(width,height) for `.circle`; `PiPGeometry.squareRoundedCornerRatio *
    /// min(width,height)` for `.roundedSquare`. Consumed by the mask
    /// layer (SwiftUI uses `.clipShape(RoundedRectangle(cornerRadius:))`,
    /// the compositor uses a `CAShapeLayer` path).
    public let cornerRadius: CGFloat

    /// Border stroke width in canvas pixels (already clamped >= 0).
    public let borderWidth: CGFloat

    /// Whether to draw a drop shadow around the thumbnail. Shadow radius
    /// / offset are derived in the renderer from the canvas size, not
    /// stored here, so this is a simple flag.
    public let shadowEnabled: Bool

    /// The layout's shape, re-exposed for renderers that take different
    /// paths per shape (e.g. SwiftUI's `Circle()` vs `RoundedRectangle`).
    public let shape: PiPLayout.Shape


    public init(
        rect: CGRect,
        scale: CGFloat,
        cornerRadius: CGFloat,
        borderWidth: CGFloat,
        shadowEnabled: Bool,
        shape: PiPLayout.Shape
    ) {
        self.rect = rect
        self.scale = scale
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.shadowEnabled = shadowEnabled
        self.shape = shape
    }

    /// Fraction of min(width,height) used as the corner radius for
    /// `.roundedSquare`. ~18% matches the iOS app-icon superellipse
    /// feel without going fully circular.
    public static let squareRoundedCornerRatio: CGFloat = 0.18

    /// Compute the PiP geometry for an overlay rendered on the canvas.
    ///
    /// - Parameters:
    ///   - layout: the per-segment `PiPLayout`. Clamped via
    ///     `normalized()` here so callers don't have to remember to.
    ///   - canvasSize: the composed-output canvas size (e.g. 1920×1080).
    ///   - sourceFrameSize: the overlay source frame's on-canvas size
    ///     BEFORE PiP transform — typically the canvas size itself
    ///     (since overlay-cover was the default before PiP). Used to
    ///     derive the scale factor that shrinks the overlay into
    ///     `rect`. Must be non-zero in both dimensions; callers should
    ///     pass `canvasSize` if they don't have separate overlay
    ///     dimensions.
    public static func compute(
        layout: PiPLayout,
        canvasSize: CGSize,
        sourceFrameSize: CGSize
    ) -> PiPGeometry {
        let clamped = layout.normalized()

        let cw = max(1, canvasSize.width)
        let ch = max(1, canvasSize.height)
        let sw = max(1, sourceFrameSize.width)
        let sh = max(1, sourceFrameSize.height)

        // Target height in canvas pixels.
        let targetH = ch * CGFloat(clamped.sizeFraction)

        // Keep aspect ratio of the source frame when shrinking.
        // .square / .circle / .roundedSquare all render into the same
        // target box — the shape is a mask, not a resize strategy.
        let targetW: CGFloat = {
            switch clamped.shape {
            case .circle, .square, .roundedSquare:
                // Square-proportioned thumbnail regardless of source
                // aspect — this is what users expect from a "presenter
                // cam" PiP. The mask clips to circle/rounded; the
                // source is center-cropped by the renderer.
                return targetH
            }
        }()

        let inset = ch * CGFloat(clamped.insetFraction)

        // Position the rect at the requested corner.
        let originX: CGFloat
        let originY: CGFloat
        switch clamped.corner {
        case .topLeft:
            originX = inset
            originY = inset
        case .topRight:
            originX = cw - inset - targetW
            originY = inset
        case .bottomLeft:
            originX = inset
            originY = ch - inset - targetH
        case .bottomRight:
            originX = cw - inset - targetW
            originY = ch - inset - targetH
        }

        let rect = CGRect(x: originX, y: originY, width: targetW, height: targetH)

        // Scale is derived from the target box's height over the
        // source's height. The renderer applies this uniformly then
        // center-crops the result into `rect` for square-proportioned
        // shapes. (SwiftUI preview uses .scaledToFill()+.frame(rect).)
        let scale = targetH / sh

        let cornerRadius: CGFloat = {
            switch clamped.shape {
            case .square: return 0
            case .circle: return min(targetW, targetH) / 2
            case .roundedSquare:
                return min(targetW, targetH) * Self.squareRoundedCornerRatio
            }
        }()

        // Suppress unused warning in case scale math changes and we
        // stop reading sw for a while.
        _ = sw

        return PiPGeometry(
            rect: rect,
            scale: scale,
            cornerRadius: cornerRadius,
            borderWidth: max(0, CGFloat(clamped.borderWidthPx)),
            shadowEnabled: clamped.shadowEnabled,
            shape: clamped.shape
        )
    }
}
