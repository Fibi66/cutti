import SwiftUI
import CuttiKit

/// Inspector-style bottom sheet for editing the selected overlay
/// segment's free-transform values (position / scale / rotation /
/// opacity). Mirrors macOS `FreeTransformInspector` but squished into
/// a single scrollable column suitable for phones and iPads.
///
/// Slider drags coalesce updates via `pushUndo = false` mid-drag and
/// push a single undo snapshot on `onEditingChanged(false)`, matching
/// the coalescing pattern used by `PiPOpacitySheet`.
struct FreeTransformSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    private var current: FreeTransform {
        let seg = document.selectedSegment
            ?? document.firstOverlaySegment
        return seg?.freeTransform ?? .identity
    }

    private var hasTarget: Bool {
        document.firstOverlaySegment != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if hasTarget {
                    VStack(spacing: 20) {
                        group("位置 X", value: current.positionX, range: -1...2, step: 0.01, format: "%.2f") { v, pushUndo in
                            document.updateSelectedFreeTransform(pushUndo: pushUndo) { $0.positionX = v }
                        }
                        group("位置 Y", value: current.positionY, range: -1...2, step: 0.01, format: "%.2f") { v, pushUndo in
                            document.updateSelectedFreeTransform(pushUndo: pushUndo) { $0.positionY = v }
                        }
                        group("缩放", value: current.scale, range: 0.1...5, step: 0.01, format: "%.2fx") { v, pushUndo in
                            document.updateSelectedFreeTransform(pushUndo: pushUndo) { $0.scale = v }
                        }
                        group("旋转", value: current.rotationDegrees, range: -180...180, step: 1, format: "%.0f°") { v, pushUndo in
                            document.updateSelectedFreeTransform(pushUndo: pushUndo) { $0.rotationDegrees = v }
                        }
                        group("不透明度", value: current.opacity, range: 0...1, step: 0.01, format: "%.0f%%", displayMultiplier: 100) { v, pushUndo in
                            document.updateSelectedFreeTransform(pushUndo: pushUndo) { $0.opacity = v }
                        }

                        Button(role: .destructive) {
                            _ = document.resetSelectedFreeTransform()
                        } label: {
                            Label("重置为默认", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("请先添加一段画中画或叠加素材")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(40)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("自由变换")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func group(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        displayMultiplier: Double = 1,
        onChange: @escaping (Double, Bool) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L(title))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: format, value * displayMultiplier))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { onChange($0, false) }
                ),
                in: range,
                step: step,
                onEditingChanged: { editing in
                    if !editing { onChange(value, true) }
                }
            )
            .tint(.yellow)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}
