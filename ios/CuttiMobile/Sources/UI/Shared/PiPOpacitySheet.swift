import SwiftUI
import CuttiKit

/// Compact slider sheet that edits the opacity of the currently-selected
/// PiP (picture-in-picture) overlay segment. Presented from the PiP tab
/// in ToolDock. Follows the same pattern as the other short adjust
/// sheets (volume / speed / fade): `.height(220)` detent, live slider
/// wrapped in a begin/end interactive-edit pair so one drag = one undo.
struct PiPOpacitySheet: View {
    @EnvironmentObject private var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double = 1.0
    @State private var didBegin = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("透明度")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(percent(value))
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }

            Slider(
                value: Binding(
                    get: { value },
                    set: { newValue in
                        if !didBegin {
                            document.beginInteractiveEdit()
                            didBegin = true
                        }
                        value = newValue
                        document.setSelectedPiPOpacity(newValue)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing, didBegin {
                        document.endInteractiveEdit()
                        didBegin = false
                    }
                }
            )
            .tint(Color(red: 0.95, green: 0.25, blue: 0.35))

            Button("完成") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
        }
        .padding(20)
        .background(Color.black)
        .onAppear {
            value = currentOpacity()
        }
    }

    private func currentOpacity() -> Double {
        if let seg = document.selectedSegment, seg.pipLayout != nil {
            return seg.freeTransform?.opacity ?? 1.0
        }
        return document.firstPiPSegment?.freeTransform?.opacity ?? 1.0
    }

    private func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}
