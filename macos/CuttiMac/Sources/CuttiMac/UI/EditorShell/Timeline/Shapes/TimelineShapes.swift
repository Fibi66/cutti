import SwiftUI

// MARK: - Triangle

/// Filled triangle pointing down. Used by the timeline ruler chevron and
/// the playhead arrow. Extracted from `TimelineDock.swift` for locality.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}

// MARK: - Diagonal hatch texture

/// Simple diagonal-hatch pattern used to overlay a "this is hidden /
/// inactive" texture on top of pills whose video has been toggled off.
/// Drawn as a Path so it composes with any clip-shape the caller uses.
struct DiagonalHatch: Shape {
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let totalSpan = rect.width + rect.height
        var x: CGFloat = -rect.height
        while x < totalSpan {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.height))
            x += spacing
        }
        return path
    }
}

// MARK: - Track row separator modifier

/// Adds a 1pt hairline separator along the bottom edge of a track row
/// so adjacent lanes read as discrete bands — mirrors the
/// `borderBottom: 1px solid ${borderSoft}` rule on OBTrack in the
/// Obsidian reference. Applied via `.modifier(TrackRowSeparator())`
/// to every lane (overlay / V1 / detached audio / subtitle) so the
/// styling stays in one place.
struct TrackRowSeparator: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(
            Rectangle()
                .fill(EditorShellStyle.obBorderSoft)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
