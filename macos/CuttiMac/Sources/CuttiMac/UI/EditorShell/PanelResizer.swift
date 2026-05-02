import SwiftUI

// A thin vertical drag handle that resizes the panel on one side of
// it. `reversed` flips the drag direction so the right-side panel
// grows when dragging left instead of right.
//
// `width` is the live (per-frame) width the panel renders at; the
// caller is expected to back it with @State so drag-to-resize updates
// are local and smooth. `onCommit` fires once on drag end so the
// caller can persist the final width to @AppStorage without writing
// on every pointer movement (those per-tick writes were causing the
// whole window to jitter during drags).
struct PanelResizer: View {
    @Binding var width: Double
    let min: Double
    let max: Double
    var reversed: Bool = false
    var onCommit: ((Double) -> Void)? = nil

    // Anchor captured on drag start. We measure the drag in global
    // screen coordinates, not the gesture's local translation, because
    // the resizer moves with the panel as the user drags — if we used
    // translation relative to the resizer itself, the coordinate
    // reference moves under the finger and introduces a feedback loop
    // that reads as jitter.
    @State private var dragStartGlobalX: CGFloat? = nil
    @State private var dragStartWidth: Double? = nil
    @State private var isHovering: Bool = false

    private var isActive: Bool { isHovering || dragStartWidth != nil }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .overlay(
                Rectangle()
                    .fill(isActive ? EditorShellStyle.accentSolid.opacity(0.55) : Color.clear)
                    .frame(width: 2)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = width
                            dragStartGlobalX = value.startLocation.x
                        }
                        guard
                            let anchor = dragStartWidth,
                            let startX = dragStartGlobalX
                        else { return }
                        let rawDelta = value.location.x - startX
                        let delta = reversed ? -rawDelta : rawDelta
                        let next = anchor + Double(delta)
                        width = Swift.min(Swift.max(next, min), max)
                    }
                    .onEnded { _ in
                        let final = width
                        dragStartWidth = nil
                        dragStartGlobalX = nil
                        onCommit?(final)
                    }
            )
    }
}

