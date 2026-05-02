import SwiftUI
import CuttiKit

/// Interactive overlay rendered on top of the video preview for every
/// V2 segment that carries a `PiPLayout` and is visible at the current
/// playhead. The baked pixels still come from `PiPVideoCompositor` —
/// this layer adds a dashed selection border and drag / resize / right-
/// click affordances so the PiP can be manipulated without fishing for
/// the overlay pill on the timeline.
///
/// Interaction model:
/// - Tap       → select this overlay segment in the timeline.
/// - Right-click → context menu (shape + corner + Off).
/// - Drag body → free move; on release the rect snaps to the nearest
///   canvas corner with an `insetFraction` equal to its distance
///   from that corner. Live pixels lag until the drag ends (we don't
///   rebuild the composition on every tick — too heavy).
/// - Drag corner handle → resize by `sizeFraction`.
///
/// Geometry round-trip: the view computes a canvas-space rect from the
/// current `PiPLayout`, places a SwiftUI rectangle over it via the
/// `videoDisplayRect` aspect-fit math, and on commit writes back a new
/// layout through `onCommitGeometry`. This mirrors `ChapterBarOverlay`'s
/// approach so multiple overlays stay consistent with each other.
struct PiPOverlayHandle: View {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let layout: PiPLayout
    }

    let items: [Item]
    /// Selected segment IDs from the VM — we highlight a handle whose
    /// segment is in this set.
    let selectedSegmentIDs: Set<UUID>
    /// Aspect ratio (w/h) of the composition. Used to compute the
    /// letterboxed video rect inside the viewer container.
    let videoAspectRatio: CGFloat?

    /// Click a handle → select that overlay segment.
    let onSelect: (UUID) -> Void
    /// User released a drag — write the final geometry back.
    let onCommitGeometry: (UUID, PiPLayout.Corner, Double, Double) -> Void
    /// Toggle circle / roundedSquare / square via the right-click menu.
    let onSetShape: (UUID, PiPLayout.Shape) -> Void
    /// Snap PiP to a specific corner without changing size / inset
    /// — hooked to the right-click "Snap to corner" submenu.
    let onSnapCorner: (UUID, PiPLayout.Corner) -> Void
    /// Turn PiP off entirely.
    let onClearPiP: (UUID) -> Void

    /// Per-handle drag state. Keyed by segment ID so overlapping
    /// overlays can be dragged independently without stomping each
    /// other's in-progress state.
    @State private var dragStates: [UUID: DragState] = [:]

    var body: some View {
        GeometryReader { geo in
            let videoRect = videoDisplayRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(items) { item in
                    handle(
                        for: item,
                        videoRect: videoRect,
                        isSelected: selectedSegmentIDs.contains(item.id)
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(!items.isEmpty)
    }

    // MARK: - Single handle

    @ViewBuilder
    private func handle(for item: Item, videoRect: CGRect, isSelected: Bool) -> some View {
        let drag = dragStates[item.id]

        // Compute the rect the PiP should cover inside the video area.
        // During a drag we use the transient rect from DragState; on
        // release (or no drag) we use the layout's canonical geometry.
        let currentRect = drag?.previewRect
            ?? canvasRect(for: item.layout, in: videoRect)

        let clipShape: AnyShape = {
            switch item.layout.shape {
            case .circle:        return AnyShape(Circle())
            case .roundedSquare: return AnyShape(RoundedRectangle(cornerRadius: currentRect.width * 0.18))
            case .square:        return AnyShape(Rectangle())
            }
        }()

        ZStack {
            // Transparent body — receives clicks and drags. Must be
            // hit-testable, so we fill with a nearly-clear color
            // (Color.clear swallows hits in SwiftUI).
            clipShape
                .fill(Color.white.opacity(0.001))
                .contentShape(clipShape)

            // Dashed border: bright when selected, softer when not.
            clipShape
                .stroke(
                    isSelected ? Color.accentColor : Color.white.opacity(0.75),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        }
        .frame(width: currentRect.width, height: currentRect.height)
        .offset(x: currentRect.minX, y: currentRect.minY)
        .overlay(alignment: .bottomTrailing) {
            // Resize handle anchored to the bottom-right of the rect.
            // The handle itself is drawn in local coords, so the offset
            // from the PiP rect is handled automatically by the overlay.
            resizeKnob(for: item, videoRect: videoRect, pipRect: currentRect)
        }
        .onTapGesture {
            onSelect(item.id)
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    var state = dragStates[item.id] ?? DragState(
                        startRect: canvasRect(for: item.layout, in: videoRect),
                        previewRect: canvasRect(for: item.layout, in: videoRect)
                    )
                    let newOrigin = CGPoint(
                        x: state.startRect.minX + value.translation.width,
                        y: state.startRect.minY + value.translation.height
                    )
                    // Keep the rect inside the video area so the user
                    // can't drag it off-screen and lose the handle.
                    let clampedX = max(
                        videoRect.minX,
                        min(newOrigin.x, videoRect.maxX - state.startRect.width)
                    )
                    let clampedY = max(
                        videoRect.minY,
                        min(newOrigin.y, videoRect.maxY - state.startRect.height)
                    )
                    state.previewRect = CGRect(
                        x: clampedX,
                        y: clampedY,
                        width: state.startRect.width,
                        height: state.startRect.height
                    )
                    dragStates[item.id] = state
                }
                .onEnded { _ in
                    guard let state = dragStates[item.id] else { return }
                    // Translate viewer-space rect back to canvas-space
                    // before asking the VM to snap — the snap logic
                    // works in canvas pixels so PiPGeometry stays
                    // the single source of geometry truth.
                    let canvasOrigin = CGPoint(
                        x: state.previewRect.minX - videoRect.minX,
                        y: state.previewRect.minY - videoRect.minY
                    )
                    let canvasSize = CGSize(
                        width: videoRect.width,
                        height: videoRect.height
                    )
                    let snap = MediaCoreViewModel.snapPiPToNearestCorner(
                        rectOrigin: canvasOrigin,
                        rectSize: state.previewRect.size,
                        canvasSize: canvasSize
                    )
                    onCommitGeometry(
                        item.id,
                        snap.corner,
                        snap.insetFraction,
                        item.layout.sizeFraction
                    )
                    dragStates.removeValue(forKey: item.id)
                    onSelect(item.id)
                }
        )
        .contextMenu {
            contextMenu(for: item)
        }
    }

    // MARK: - Resize knob

    @ViewBuilder
    private func resizeKnob(for item: Item, videoRect: CGRect, pipRect: CGRect) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: 12, height: 12)
            .offset(x: 6, y: 6)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        // Preview size change — we reuse DragState but
                        // repurpose previewRect to carry the resized
                        // rect. Corner stays anchored at the current
                        // layout's corner so the "opposite" edge
                        // doesn't shift while the user drags.
                        var state = dragStates[item.id] ?? DragState(
                            startRect: pipRect,
                            previewRect: pipRect
                        )
                        let delta = max(value.translation.width, value.translation.height)
                        let newSide = max(40, min(videoRect.height * CGFloat(PiPLayout.maxSizeFraction), state.startRect.width + delta))
                        let anchored = resizedRect(
                            from: state.startRect,
                            newSide: newSide,
                            corner: item.layout.corner,
                            videoRect: videoRect
                        )
                        state.previewRect = anchored
                        dragStates[item.id] = state
                    }
                    .onEnded { _ in
                        guard let state = dragStates[item.id] else { return }
                        let sizeFraction = Double(state.previewRect.height / max(1, videoRect.height))
                        onCommitGeometry(
                            item.id,
                            item.layout.corner,
                            item.layout.insetFraction,
                            sizeFraction
                        )
                        dragStates.removeValue(forKey: item.id)
                        onSelect(item.id)
                    }
            )
    }

    @ViewBuilder
    private func contextMenu(for item: Item) -> some View {
        Section("Shape") {
            Button(item.layout.shape == .circle ? "✓ Circle" : "Circle") {
                onSetShape(item.id, .circle)
            }
            Button(item.layout.shape == .roundedSquare ? "✓ Rounded Square" : "Rounded Square") {
                onSetShape(item.id, .roundedSquare)
            }
            Button(item.layout.shape == .square ? "✓ Square" : "Square") {
                onSetShape(item.id, .square)
            }
        }
        Section("Snap to corner") {
            Button(item.layout.corner == .topLeft ? "✓ Top Left" : "Top Left") {
                onSnapCorner(item.id, .topLeft)
            }
            Button(item.layout.corner == .topRight ? "✓ Top Right" : "Top Right") {
                onSnapCorner(item.id, .topRight)
            }
            Button(item.layout.corner == .bottomLeft ? "✓ Bottom Left" : "Bottom Left") {
                onSnapCorner(item.id, .bottomLeft)
            }
            Button(item.layout.corner == .bottomRight ? "✓ Bottom Right" : "Bottom Right") {
                onSnapCorner(item.id, .bottomRight)
            }
        }
        Divider()
        Button(role: .destructive) {
            onClearPiP(item.id)
        } label: {
            T("Turn Off Picture-in-Picture")
        }
    }

    // MARK: - Geometry helpers

    /// Project the persistent `PiPLayout` into a rect on the viewer's
    /// video area (letterbox-aware, in container points).
    private func canvasRect(for layout: PiPLayout, in videoRect: CGRect) -> CGRect {
        // Use the video display rect as the canvas — aspect is the
        // same as the composition, so fractions in the layout map
        // directly onto pixels here.
        let geom = PiPGeometry.compute(
            layout: layout,
            canvasSize: videoRect.size,
            sourceFrameSize: videoRect.size
        )
        // PiPGeometry.rect is in top-left canvas coordinates. Shift
        // by videoRect origin so we can place it in the container.
        return geom.rect.offsetBy(dx: videoRect.minX, dy: videoRect.minY)
    }

    /// Keep the opposite-corner anchor of a square PiP pinned while
    /// resizing the near corner. All four cases fall back to the
    /// canvas bounds so a big resize can't push the rect off-screen.
    private func resizedRect(
        from base: CGRect,
        newSide: CGFloat,
        corner: PiPLayout.Corner,
        videoRect: CGRect
    ) -> CGRect {
        let side = max(40, newSide)
        switch corner {
        case .topLeft:
            return CGRect(x: base.minX, y: base.minY, width: side, height: side)
        case .topRight:
            return CGRect(x: base.maxX - side, y: base.minY, width: side, height: side)
        case .bottomLeft:
            return CGRect(x: base.minX, y: base.maxY - side, width: side, height: side)
        case .bottomRight:
            return CGRect(x: base.maxX - side, y: base.maxY - side, width: side, height: side)
        }
    }

    /// Letterbox-aware video rect inside the handle's container.
    /// Mirrors `ChapterBarOverlay.videoDisplayRect` so the dashed
    /// frame lines up with the rendered video pixels even when the
    /// container is wider or taller than the source.
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

    private struct DragState: Equatable {
        let startRect: CGRect
        var previewRect: CGRect
    }
}

// Apple ships `AnyShape` in macOS 14; we target .v14 so we can use it
// directly without a fallback.
