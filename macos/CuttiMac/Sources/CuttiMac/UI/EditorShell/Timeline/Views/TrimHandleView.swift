import AppKit
import SwiftUI

// MARK: - Horizontal edge

/// Which edge of a segment a trim gesture is modifying. Used both by
/// `TrimHandleView` and by `MediaCoreViewModel.liveTrim` so the two
/// ends of the drag agree on orientation.
enum HorizontalEdge {
    case leading, trailing
}

// MARK: - Cursor modifier

/// Pushes `cursor` onto the AppKit cursor stack while the pointer is
/// inside the receiver, popping it on exit. File-private to the
/// timeline trim handle (only consumer) — not a general-purpose helper.
fileprivate extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Trim handle view

/// Draggable handle rendered on the leading / trailing edge of a
/// timeline segment. Reports drag translation (in global coordinates,
/// see note below) to its owner, which translates the delta into a
/// trim in seconds.
struct TrimHandleView: View {
    let edge: HorizontalEdge
    let height: CGFloat
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    private let handleWidth: CGFloat = Self.handleWidth
    static let handleWidth: CGFloat = 8
    /// Width of the small corner filler squares that plug the segment's
    /// rounded-corner gap at the very top and very bottom of the
    /// handle. Matches `EditorShellStyle.timelineClipRadius`. The
    /// handle's main body stays 8pt wide at the segment's exterior so
    /// it doesn't overlap the playhead (which is drawn at the segment
    /// boundary) — only these 3×3 squares poke into the segment, and
    /// only at the corners that would otherwise show black.
    private static let cornerFiller: CGFloat = 3
    // Invisible padding around the visible handle so a user can
    // reliably grab it with a mouse; 8pt of visible chrome is too
    // narrow a target on its own.
    private let hitSlop: CGFloat = 8

    var body: some View {
        let bar = RoundedRectangle(cornerRadius: 2)
            .fill(EditorShellStyle.accentSolid.opacity(0.9))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.black.opacity(0.35), lineWidth: 0.5)
            )
            .frame(width: handleWidth, height: height)
            .shadow(color: Color.black.opacity(0.25), radius: 1.5, x: 0, y: 0)

        // Two 3×3 yellow squares that poke into the segment exactly
        // over its rounded top/bottom corner on the handle side. They
        // cover the crescent gap the corner radius would otherwise
        // expose to the black timeline background, without making the
        // main bar any wider (so the playhead line, drawn at the
        // segment boundary, still lands at the bar's inner edge
        // instead of inside yellow chrome).
        let fillerSize = Self.cornerFiller
        let innerAlignTop: Alignment = edge == .leading ? .topTrailing : .topLeading
        let innerAlignBottom: Alignment = edge == .leading ? .bottomTrailing : .bottomLeading
        let fillerOffsetX: CGFloat = edge == .leading ? fillerSize : -fillerSize

        ZStack(alignment: edge == .leading ? .leading : .trailing) {
            bar
                .overlay(alignment: innerAlignTop) {
                    Rectangle()
                        .fill(EditorShellStyle.accentSolid.opacity(0.9))
                        .frame(width: fillerSize, height: fillerSize)
                        .offset(x: fillerOffsetX)
                }
                .overlay(alignment: innerAlignBottom) {
                    Rectangle()
                        .fill(EditorShellStyle.accentSolid.opacity(0.9))
                        .frame(width: fillerSize, height: fillerSize)
                        .offset(x: fillerOffsetX)
                }
        }
        .frame(
            width: handleWidth + hitSlop * 2,
            height: height,
            alignment: edge == .leading ? .leading : .trailing
        )
        .contentShape(Rectangle())
        .cursor(.resizeLeftRight)
        // highPriorityGesture (not .gesture): the overlay pill attaches
        // its OWN DragGesture for repositioning the whole clip on the
        // timeline. With plain .gesture SwiftUI lets the outer parent
        // drag win, so the trim handle never fires — visible as
        // "dragging the right edge does nothing on image overlays".
        // Elevating to highPriority guarantees the trim gesture
        // handles hits within the handle's bounds. V1 primary trims
        // are unaffected because V1 segments have no competing
        // pill-level drag.
        .highPriorityGesture(
            // Use .global coordinate space so that `translation.width`
            // is measured against a fixed screen-space origin. If we
            // used the default .local space, the handle's own frame
            // shifts every time its parent segment grows (the whole
            // point of trimming), which means the local coordinate
            // origin moves with the handle → translation reads near
            // zero → next frame overshoots → feedback loop. That's
            // what produced the visible jitter/shake while trimming.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    onDragChanged(value.translation.width)
                }
                .onEnded { value in
                    onDragEnded(value.translation.width)
                }
        )
    }
}
