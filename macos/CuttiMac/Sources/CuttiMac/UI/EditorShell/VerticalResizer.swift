import SwiftUI

/// Horizontal drag handle that resizes a pane above / below it by
/// adjusting the bound `height` of the lower pane. Mirrors
/// `PanelResizer` but along the vertical axis: dragging DOWN shrinks
/// the lower pane (timeline) and lets the upper region (viewer /
/// right rail / chat) grow to fill the reclaimed space.
///
/// Drag position is measured in global screen coordinates so the
/// handle can travel with the pane edge without creating a feedback
/// loop (see `PanelResizer` for the same rationale).
struct VerticalResizer: View {
    @Binding var height: Double
    let min: Double
    let max: Double
    var onCommit: ((Double) -> Void)? = nil

    @State private var dragStartGlobalY: CGFloat? = nil
    @State private var dragStartHeight: Double? = nil
    @State private var isHovering: Bool = false

    private var isActive: Bool { isHovering || dragStartHeight != nil }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .overlay(
                Rectangle()
                    .fill(isActive ? EditorShellStyle.accentSolid.opacity(0.55) : Color.clear)
                    .frame(height: 2)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = height
                            dragStartGlobalY = value.startLocation.y
                        }
                        guard
                            let anchor = dragStartHeight,
                            let startY = dragStartGlobalY
                        else { return }
                        // Pointer moving DOWN (positive dy) shrinks the
                        // lower pane; moving UP grows it.
                        let dy = value.location.y - startY
                        let next = anchor - Double(dy)
                        height = Swift.min(Swift.max(next, min), max)
                    }
                    .onEnded { _ in
                        let final = height
                        dragStartHeight = nil
                        dragStartGlobalY = nil
                        onCommit?(final)
                    }
            )
    }
}
