import SwiftUI
import CuttiKit

/// Interactive handles for a single overlay segment's `FreeTransform`.
/// Sits on top of the viewer's rendered video rect (aspect-fit inside
/// the container) and surfaces three industry-standard manipulators:
///
///   • **Body drag** — translates the layer in canvas space. The
///     pointer delta is converted to normalized 0…1 coords using the
///     aspect-fit videoRect (mirrors PiPOverlayHandle's letterbox
///     math so the handles line up with the rendered pixels).
///   • **Corner knobs** — uniform scale. The knob is dragged; the
///     ratio of post- to pre-drag distance-from-center multiplies
///     the current scale.
///   • **Top stem + knob** — rotation. The knob's angle around the
///     layer center drives `rotationDegrees` (UI-clockwise, 0 = up).
///
/// The handles stream in-progress updates with `commit: false` on
/// every drag tick and fire once with `commit: true` on gesture end,
/// so one undo step captures the whole manipulation (matches the
/// PiP handle convention).
struct FreeTransformHandle: View {

    struct Target: Equatable {
        let segmentID: UUID
        let freeTransform: FreeTransform
        /// Source aspect (width / height). Used to draw a correctly-
        /// proportioned handle box; the actual rendered size is
        /// `scale * fit(canvas, source)`.
        let sourceAspect: CGFloat
    }

    let target: Target
    /// Canvas aspect ratio for the composed preview. Lets the handle
    /// compute the letterboxed videoRect inside its container so the
    /// box sits over the actual rendered pixels.
    let videoAspectRatio: CGFloat?
    /// Called for every in-flight drag tick (`commit: false`) and once
    /// with `commit: true` on .onEnded.
    let onUpdate: (UUID, FreeTransform, Bool) -> Void

    /// Live transform during a drag. When nil we read `target.freeTransform`.
    @State private var live: FreeTransform?

    /// Snapshot of the transform at the instant the drag began. Used as
    /// the BASE for translation / scale / rotation math so we don't
    /// double-count cumulative drag deltas against a `target` that the
    /// view model is rewriting on every tick via `onUpdate(commit:false)`.
    /// Without this, `target.freeTransform + translation.width / videoRect`
    /// feeds the last-written value back in and the delta compounds
    /// quadratically — dragging a handful of points launches the image
    /// off-screen.
    @State private var dragBase: FreeTransform?

    /// Geometry captured alongside `dragBase` for the corner (uniform-
    /// scale) handle. Frozen at drag start so the rendered layerRect
    /// moving with the live transform doesn't pull the reference point
    /// out from under the gesture mid-drag.
    private struct CornerAnchor {
        let base: FreeTransform
        let rotatedPoint: CGPoint
        let center: CGPoint
        let startDistance: CGFloat
    }
    @State private var cornerAnchor: CornerAnchor?

    /// Geometry captured alongside `dragBase` for the rotation handle.
    /// Same rationale as `cornerAnchor`.
    private struct RotationAnchor {
        let base: FreeTransform
        let rotatedTip: CGPoint
        let center: CGPoint
    }
    @State private var rotationAnchor: RotationAnchor?

    var body: some View {
        GeometryReader { geo in
            let videoRect = videoDisplayRect(in: geo.size)
            let current = live ?? target.freeTransform
            let lrect = layerRect(in: videoRect, transform: current)

            ZStack(alignment: .topLeading) {
                rotatedFrame(rect: lrect, rotationDegrees: current.rotationDegrees)
                    .allowsHitTesting(false)

                bodyHandle(rect: lrect, transform: current, videoRect: videoRect)

                ForEach(Corner.all, id: \.self) { corner in
                    cornerHandle(corner: corner, layerRect: lrect, transform: current)
                }

                rotationHandle(layerRect: lrect, transform: current)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    // MARK: - Pieces

    private func rotatedFrame(rect: CGRect, rotationDegrees: Double) -> some View {
        Rectangle()
            .strokeBorder(
                EditorShellStyle.accentSolid,
                style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])
            )
            .frame(width: rect.width, height: rect.height)
            .rotationEffect(.degrees(rotationDegrees), anchor: .center)
            .position(x: rect.midX, y: rect.midY)
    }

    private func bodyHandle(rect: CGRect, transform: FreeTransform, videoRect: CGRect) -> some View {
        Color.white.opacity(0.001)
            .frame(width: rect.width, height: rect.height)
            .rotationEffect(.degrees(transform.rotationDegrees), anchor: .center)
            .position(x: rect.midX, y: rect.midY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragBase ?? target.freeTransform
                        if dragBase == nil { dragBase = base }
                        var next = base
                        let dxNorm = value.translation.width / max(1, videoRect.width)
                        let dyNorm = value.translation.height / max(1, videoRect.height)
                        next.positionX = base.positionX + Double(dxNorm)
                        next.positionY = base.positionY + Double(dyNorm)
                        live = next
                        onUpdate(target.segmentID, next, false)
                    }
                    .onEnded { _ in
                        if let next = live { onUpdate(target.segmentID, next, true) }
                        live = nil
                        dragBase = nil
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
    }

    private func cornerHandle(
        corner: Corner,
        layerRect: CGRect,
        transform: FreeTransform
    ) -> some View {
        let center = CGPoint(x: layerRect.midX, y: layerRect.midY)
        let base = corner.point(in: layerRect)
        let rotated = rotate(point: base, around: center, degrees: transform.rotationDegrees)
        let startDistance = hypot(base.x - center.x, base.y - center.y)

        return Circle()
            .fill(EditorShellStyle.accentSolid)
            .frame(width: 10, height: 10)
            .position(x: rotated.x, y: rotated.y)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let anchor: CornerAnchor
                        if let existing = cornerAnchor {
                            anchor = existing
                        } else {
                            anchor = CornerAnchor(
                                base: target.freeTransform,
                                rotatedPoint: rotated,
                                center: center,
                                startDistance: startDistance
                            )
                            cornerAnchor = anchor
                        }
                        guard anchor.startDistance > 1 else { return }
                        let pointer = CGPoint(
                            x: anchor.rotatedPoint.x + value.translation.width,
                            y: anchor.rotatedPoint.y + value.translation.height
                        )
                        let d = hypot(pointer.x - anchor.center.x, pointer.y - anchor.center.y)
                        let ratio = max(0.05, d / anchor.startDistance)
                        var next = anchor.base
                        next.scale = anchor.base.scale * Double(ratio)
                        live = next
                        onUpdate(target.segmentID, next, false)
                    }
                    .onEnded { _ in
                        if let next = live { onUpdate(target.segmentID, next, true) }
                        live = nil
                        cornerAnchor = nil
                    }
            )
    }

    private func rotationHandle(
        layerRect: CGRect,
        transform: FreeTransform
    ) -> some View {
        let center = CGPoint(x: layerRect.midX, y: layerRect.midY)
        let stemBase = CGPoint(x: layerRect.midX, y: layerRect.minY)
        let stemTip = CGPoint(x: layerRect.midX, y: layerRect.minY - 24)
        let rotatedBase = rotate(point: stemBase, around: center, degrees: transform.rotationDegrees)
        let rotatedTip = rotate(point: stemTip, around: center, degrees: transform.rotationDegrees)

        return ZStack {
            Path { p in
                p.move(to: rotatedBase)
                p.addLine(to: rotatedTip)
            }
            .stroke(EditorShellStyle.accentSolid, lineWidth: 1.2)

            Circle()
                .fill(EditorShellStyle.accentSolid)
                .frame(width: 10, height: 10)
                .position(x: rotatedTip.x, y: rotatedTip.y)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let anchor: RotationAnchor
                            if let existing = rotationAnchor {
                                anchor = existing
                            } else {
                                anchor = RotationAnchor(
                                    base: target.freeTransform,
                                    rotatedTip: rotatedTip,
                                    center: center
                                )
                                rotationAnchor = anchor
                            }
                            let pointer = CGPoint(
                                x: anchor.rotatedTip.x + value.translation.width,
                                y: anchor.rotatedTip.y + value.translation.height
                            )
                            let dx = pointer.x - anchor.center.x
                            let dy = pointer.y - anchor.center.y
                            let radians = atan2(dy, dx)
                            // atan2 returns 0 along +X; our "up" is -Y,
                            // which is -π/2. Shift so up = 0, clockwise
                            // positive.
                            var deg = (radians * 180 / .pi) + 90
                            if deg > 180 { deg -= 360 }
                            if deg < -180 { deg += 360 }
                            var next = anchor.base
                            next.rotationDegrees = Double(deg)
                            live = next
                            onUpdate(target.segmentID, next, false)
                        }
                        .onEnded { _ in
                            if let next = live { onUpdate(target.segmentID, next, true) }
                            live = nil
                            rotationAnchor = nil
                        }
                )
        }
    }

    // MARK: - Geometry

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        static let all: [Corner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    /// Unrotated AABB of the layer inside `videoRect` for a given
    /// FreeTransform. At scale 1.0 the layer aspect-fits the canvas
    /// (same rule as `FreeTransformGeometry.fitSize`).
    private func layerRect(in videoRect: CGRect, transform: FreeTransform) -> CGRect {
        let canvasAspect = videoRect.width / max(1, videoRect.height)
        let fitWidth: CGFloat
        let fitHeight: CGFloat
        if target.sourceAspect > canvasAspect {
            fitWidth = videoRect.width
            fitHeight = videoRect.width / target.sourceAspect
        } else {
            fitHeight = videoRect.height
            fitWidth = videoRect.height * target.sourceAspect
        }
        let w = fitWidth * CGFloat(transform.scale)
        let h = fitHeight * CGFloat(transform.scale)
        let cx = videoRect.minX + videoRect.width * CGFloat(transform.positionX)
        let cy = videoRect.minY + videoRect.height * CGFloat(transform.positionY)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func rotate(point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        let r = degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        let cosR = cos(r)
        let sinR = sin(r)
        return CGPoint(
            x: center.x + dx * cosR - dy * sinR,
            y: center.y + dx * sinR + dy * cosR
        )
    }

    /// Letterbox-aware video rect — mirrors PiPOverlayHandle.
    private func videoDisplayRect(in size: CGSize) -> CGRect {
        guard let ratio = videoAspectRatio, ratio > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let containerRatio = size.width / max(1, size.height)
        if containerRatio > ratio {
            let h = size.height
            let w = h * ratio
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: h)
        } else {
            let w = size.width
            let h = w / ratio
            return CGRect(x: 0, y: (size.height - h) / 2, width: w, height: h)
        }
    }
}
