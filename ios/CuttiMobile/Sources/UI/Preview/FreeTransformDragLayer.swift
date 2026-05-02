import SwiftUI
import CuttiKit

/// Direct-on-canvas drag / pinch / rotation handle for the currently
/// active overlay segment's `FreeTransform`. Mirrors CapCut's dashed
/// bounding box: drag the box body to translate, pinch to scale, two-
/// finger rotate to spin. The FreeTransformSheet's sliders remain
/// available for fine numeric tweaks — this layer is for the 90% case
/// where the user just wants to position something visually.
///
/// The proxy is a square sized as `canvasShortSide × scale`. We don't
/// look up the source asset's natural aspect because the proxy is a
/// handle, not a thumbnail — the actual overlay frame the user sees
/// behind the proxy is the source of truth for what's exported.
///
/// Only renders when the playhead sits inside an overlay segment that
/// either is selected or is the project's first overlay (matches
/// `ProjectDocument.updateSelectedFreeTransform` target resolution).
struct FreeTransformDragLayer: View {
    @EnvironmentObject var document: ProjectDocument

    @State private var dragStart: CGPoint? = nil
    @State private var pinchStartScale: Double? = nil
    @State private var rotateStartDegrees: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let canvas = geo.size
            if let target = activeTarget(),
               canvas.width > 1, canvas.height > 1 {
                let ft = target.freeTransform ?? .identity
                let baseSide = min(canvas.width, canvas.height)
                let side = max(24, baseSide * CGFloat(ft.scale))
                let cx = canvas.width * CGFloat(ft.positionX)
                let cy = canvas.height * CGFloat(ft.positionY)
                proxyBox(side: side)
                    .rotationEffect(.degrees(ft.rotationDegrees))
                    .position(x: cx, y: cy)
                    .gesture(dragGesture(canvas: canvas))
                    .gesture(SimultaneousGesture(
                        magnificationGesture(),
                        rotationGesture()
                    ))
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(activeTarget() != nil)
    }

    // MARK: - Gestures

    private func dragGesture(canvas: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    let ft = activeTarget()?.freeTransform ?? .identity
                    dragStart = CGPoint(
                        x: canvas.width * CGFloat(ft.positionX),
                        y: canvas.height * CGFloat(ft.positionY)
                    )
                }
                guard let start = dragStart else { return }
                let nx = (start.x + value.translation.width) / canvas.width
                let ny = (start.y + value.translation.height) / canvas.height
                document.updateSelectedFreeTransform(pushUndo: false) { ft in
                    ft.positionX = Double(nx)
                    ft.positionY = Double(ny)
                }
            }
            .onEnded { _ in
                if dragStart != nil {
                    document.updateSelectedFreeTransform(pushUndo: true) { _ in }
                }
                dragStart = nil
            }
    }

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchStartScale == nil {
                    pinchStartScale = (activeTarget()?.freeTransform ?? .identity).scale
                }
                guard let s0 = pinchStartScale else { return }
                document.updateSelectedFreeTransform(pushUndo: false) { ft in
                    ft.scale = s0 * Double(value)
                }
            }
            .onEnded { _ in
                if pinchStartScale != nil {
                    document.updateSelectedFreeTransform(pushUndo: true) { _ in }
                }
                pinchStartScale = nil
            }
    }

    private func rotationGesture() -> some Gesture {
        RotationGesture()
            .onChanged { angle in
                if rotateStartDegrees == nil {
                    rotateStartDegrees = (activeTarget()?.freeTransform ?? .identity).rotationDegrees
                }
                guard let r0 = rotateStartDegrees else { return }
                document.updateSelectedFreeTransform(pushUndo: false) { ft in
                    ft.rotationDegrees = r0 + angle.degrees
                }
            }
            .onEnded { _ in
                if rotateStartDegrees != nil {
                    document.updateSelectedFreeTransform(pushUndo: true) { _ in }
                }
                rotateStartDegrees = nil
            }
    }

    // MARK: - Pieces

    private func proxyBox(side: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .strokeBorder(
                    Color.white,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .background(Color.white.opacity(0.001))
            // Corner pips give the user something to grab visually.
            ForEach([(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)], id: \.0.description) { c in
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .offset(x: side / 2 * c.0, y: side / 2 * c.1)
            }
        }
        .frame(width: side, height: side)
    }

    // MARK: - Target resolution (mirrors ProjectDocument)

    private func activeTarget() -> TimelineSegment? {
        let t = document.currentTime
        // Resolve composed start of each overlay segment using
        // placementOffset — overlay segments are anchored, not
        // sequential. A segment is "active" if t∈[start, start+dur].
        for track in document.tracks where track.kind == .overlay {
            for seg in track.segments {
                let start = seg.placementOffset ?? 0
                let end = start + seg.durationSeconds
                guard t >= start && t <= end else { continue }
                if let id = document.selectedSegmentID, id == seg.id { return seg }
            }
        }
        // No active+selected match → fall back to first overlay (same
        // rule the inspector uses) so the user always has something to
        // grab if any overlay exists at the current time.
        let t2 = document.currentTime
        for track in document.tracks where track.kind == .overlay {
            for seg in track.segments {
                let start = seg.placementOffset ?? 0
                let end = start + seg.durationSeconds
                if t2 >= start && t2 <= end { return seg }
            }
        }
        return nil
    }
}
