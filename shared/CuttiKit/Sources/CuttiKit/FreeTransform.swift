import CoreGraphics

/// Free-transform controls for an overlay layer. Industry-standard
/// 2D layer parameters as found in After Effects / FCP / Premiere:
///
///   • `position` — normalized (0…1) coords of the layer center on
///     the canvas. (0.5, 0.5) is the middle. Can exceed 0…1 if the
///     user drags off-canvas.
///   • `scale` — multiplicative over the "fit" size. 1.0 = the layer
///     fills the canvas's shorter dimension (aspect-preserved).
///   • `rotationDegrees` — clockwise rotation around the layer's
///     center, in degrees. 0 = upright.
///   • `opacity` — 0…1 linear; applied last.
///
/// Fields are kept independent so each handle in the preview edits a
/// single value. Pure-value type — all conversions to CGAffineTransform
/// happen in `FreeTransformGeometry` so the UI never computes matrix
/// math on the main thread.
public struct FreeTransform: Equatable, Sendable {
    /// Canvas-normalized center, origin top-left. (0.5, 0.5) = center.
    public var positionX: Double
    /// Canvas-normalized center, origin top-left. (0.5, 0.5) = center.
    public var positionY: Double
    /// Multiplier over the aspect-fit base size. 1.0 = fit-to-canvas.
    public var scale: Double
    /// Clockwise rotation in degrees, applied around the layer center.
    public var rotationDegrees: Double
    /// 0…1 opacity; caller is responsible for clamping on edit.
    public var opacity: Double

    public init(
        positionX: Double,
        positionY: Double,
        scale: Double,
        rotationDegrees: Double,
        opacity: Double
    ) {
        self.positionX = positionX
        self.positionY = positionY
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
    }

    public static let identity = FreeTransform(
        positionX: 0.5,
        positionY: 0.5,
        scale: 1.0,
        rotationDegrees: 0,
        opacity: 1.0
    )
}

/// Pure-math helpers for turning a `FreeTransform` into the
/// CoreGraphics transforms the compositor applies. Separated from
/// the struct so the geometry can be unit-tested without importing
/// AVFoundation / CoreImage.
public enum FreeTransformGeometry {

    /// Compute the base aspect-fit size for a source of `sourceSize`
    /// rendered at FreeTransform `scale = 1` onto `canvasSize`.
    ///
    /// Convention: at scale 1.0 the layer fits inside the canvas
    /// preserving aspect (letterbox). Matches After Effects' "fit to
    /// comp width/height" starting point.
    public static func fitSize(sourceSize: CGSize, canvasSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let scale = min(
            canvasSize.width / sourceSize.width,
            canvasSize.height / sourceSize.height
        )
        return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    }

    /// Build the CoreImage-space transform that applies the given
    /// FreeTransform to a source image of `sourceSize` on a canvas of
    /// `canvasSize`.
    ///
    /// Pipeline (in order):
    ///   1. Translate source origin to its midpoint (pre-rotate).
    ///   2. Scale by fit * transform.scale — so "scale 1" equals the
    ///      aspect-fit base size.
    ///   3. Rotate by -transform.rotationDegrees (CoreImage's Y-up
    ///      coordinate system makes a CLOCKWISE UI rotation a
    ///      COUNTER-CLOCKWISE math rotation).
    ///   4. Translate to the target center in bottom-left canvas coords
    ///      (positionY is inverted because the UI uses top-left origin
    ///      while CoreImage uses bottom-left).
    public static func ciTransform(
        sourceSize: CGSize,
        canvasSize: CGSize,
        transform: FreeTransform
    ) -> CGAffineTransform {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .identity }
        let fit = fitSize(sourceSize: sourceSize, canvasSize: canvasSize)
        let sx = (fit.width * CGFloat(transform.scale)) / sourceSize.width
        let sy = (fit.height * CGFloat(transform.scale)) / sourceSize.height

        var t = CGAffineTransform(translationX: -sourceSize.width / 2, y: -sourceSize.height / 2)
        t = t.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        let radians = -CGFloat(transform.rotationDegrees) * .pi / 180
        t = t.concatenating(CGAffineTransform(rotationAngle: radians))
        let cx = canvasSize.width * CGFloat(transform.positionX)
        let cyFromTop = canvasSize.height * CGFloat(transform.positionY)
        let cyFromBottom = canvasSize.height - cyFromTop
        t = t.concatenating(CGAffineTransform(translationX: cx, y: cyFromBottom))
        return t
    }
}
