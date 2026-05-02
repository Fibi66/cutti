import SwiftUI
import UIKit
import CuttiKit

/// Invisible SwiftUI layer sized to the fitted-video rect that draws a
/// tappable / draggable proxy box for every text overlay active at the
/// current playhead. Tap ⇒ open editor sheet. Drag ⇒ live-update
/// positionX / positionY (normalized, origin bottom-left to match the
/// Core Image rasterizer). Bouncing proxies off preview edges would
/// misalign exports, so positions clamp only to the outer [0.02,0.98]
/// safe-area rather than the proxy's size.
struct TextOverlayDragLayer: View {
    @EnvironmentObject var document: ProjectDocument
    @State private var dragging: UUID? = nil
    @State private var dragStart: CGPoint = .zero
    @State private var editing: UUID? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Transparent backdrop so empty taps don't swallow
                // taps meant for the VideoPlayer underneath.
                Color.clear
                ForEach(activeOverlays()) { overlay in
                    overlayProxy(overlay, in: geo.size)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            if let id = editing {
                TextOverlayEditorSheet(overlayID: id)
                    .environmentObject(document)
                    .presentationDetents([.height(380)])
            }
        }
    }

    private func activeOverlays() -> [IOSSessionState.TextOverlay] {
        let t = document.currentTime
        return document.textOverlays.filter { t >= $0.startSeconds && t <= $0.endSeconds }
    }

    /// Mirror the rasterizer's font resolution so the on-preview proxy
    /// matches the exported glyphs. Custom font absent = system bold;
    /// italic trait applied via UIFontDescriptor so we don't synth-skew.
    private func proxyFont(for overlay: IOSSessionState.TextOverlay, size: CGFloat) -> Font {
        let italic = overlay.italic ?? false
        if let name = overlay.fontName, !name.isEmpty,
           let uiFont = UIFont(name: name, size: size) {
            let resolved: UIFont
            if italic, let desc = uiFont.fontDescriptor.withSymbolicTraits(
                uiFont.fontDescriptor.symbolicTraits.union(.traitItalic)
            ) {
                resolved = UIFont(descriptor: desc, size: size)
            } else {
                resolved = uiFont
            }
            return Font(resolved)
        }
        var sys: Font = .system(size: size, weight: .bold)
        if italic { sys = sys.italic() }
        return sys
    }

    @ViewBuilder
    private func overlayProxy(_ overlay: IOSSessionState.TextOverlay, in size: CGSize) -> some View {
        let shortSide = min(size.width, size.height)
        let pointSize = max(12, shortSide * CGFloat(overlay.fontSizeRel))
        // SwiftUI draws top-down. TextOverlay's positionY is bottom-up
        // in canvas space; invert here so the proxy tracks the exported
        // position exactly.
        let cx = size.width * CGFloat(overlay.positionX)
        let cy = size.height * (1.0 - CGFloat(overlay.positionY))

        Text(overlay.text.isEmpty ? " " : overlay.text)
            .font(proxyFont(for: overlay, size: pointSize))
            .foregroundStyle(Color(
                red: overlay.colorR, green: overlay.colorG, blue: overlay.colorB
            ))
            .shadow(color: .black.opacity(0.85), radius: pointSize * 0.08)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        dragging == overlay.id
                            ? Color(red: 0.95, green: 0.25, blue: 0.35)
                            : Color.white.opacity(0.45),
                        lineWidth: dragging == overlay.id ? 1.5 : 1
                    )
            )
            .position(x: cx, y: cy)
            .contentShape(Rectangle())
            .onTapGesture { editing = overlay.id }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragging != overlay.id {
                            dragging = overlay.id
                            dragStart = CGPoint(
                                x: CGFloat(overlay.positionX) * size.width,
                                y: (1.0 - CGFloat(overlay.positionY)) * size.height
                            )
                            document.beginInteractiveEdit()
                        }
                        let nx = dragStart.x + value.translation.width
                        let ny = dragStart.y + value.translation.height
                        let normX = max(0.02, min(0.98, nx / size.width))
                        let normY = max(0.02, min(0.98, 1.0 - ny / size.height))
                        document.updateTextOverlay(id: overlay.id) {
                            $0.positionX = Double(normX)
                            $0.positionY = Double(normY)
                        }
                    }
                    .onEnded { _ in
                        if dragging == overlay.id {
                            document.endInteractiveEdit()
                        }
                        dragging = nil
                    }
            )
    }
}
