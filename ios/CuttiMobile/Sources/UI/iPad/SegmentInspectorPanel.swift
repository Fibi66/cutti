import SwiftUI
import CuttiKit

/// iPad-only read-only inspector that surfaces the properties of
/// whatever segment is currently selected on the timeline. It mirrors
/// the state that lives inside the tool-dock sheets (volume, speed,
/// fades, colour, rotation, flip, filter/visual preset) in a single
/// always-visible panel so users on a bigger screen don't have to pop
/// sheets just to check a value.
///
/// Editing is still done via the ToolDock sheets — this view is a
/// status surface, not an editor.
struct SegmentInspectorPanel: View {
    @EnvironmentObject private var document: ProjectDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))
            ScrollView {
                if let seg = document.selectedSegment {
                    segmentBody(seg)
                } else {
                    emptyState
                }
            }
        }
        .background(Color(white: 0.07))
    }

    private var header: some View {
        HStack {
            Text("属性")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if let seg = document.selectedSegment {
                Text(formatDuration(seg.durationSeconds))
                    .font(.system(size: 12, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("未选中片段")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
            Text("在下方时间线点击片段来查看或编辑属性")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    @ViewBuilder
    private func segmentBody(_ seg: TimelineSegment) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            group("时长", content: {
                readRow("范围", "\(formatDuration(seg.range.startSeconds)) – \(formatDuration(seg.range.endSeconds))")
                divider
                readRow("播放", formatDuration(seg.durationSeconds))
            })

            group("速度", content: {
                sliderRow(
                    label: "速度",
                    value: seg.speedRate,
                    range: TimelineSegment.minimumSpeedRate ... TimelineSegment.maximumSpeedRate,
                    format: { String(format: "%.2fx", $0) },
                    onEdit: { document.setSelectedSegmentSpeed($0) }
                )
            })

            group("音频", content: {
                sliderRow(
                    label: "音量",
                    value: seg.volumeLevel,
                    range: 0 ... 1,
                    format: { $0 <= 0.01 ? "静音" : "\(Int(($0 * 100).rounded()))%" },
                    onEdit: { document.setSelectedSegmentVolume($0) }
                )
                divider
                sliderRow(
                    label: "淡入",
                    value: seg.effects.audioFadeInDuration,
                    range: 0 ... max(0.1, seg.durationSeconds / 2),
                    format: { $0 < 0.05 ? "—" : String(format: "%.1fs", $0) },
                    onEdit: { document.setSelectedSegmentFade(fadeIn: $0, fadeOut: nil) }
                )
                divider
                sliderRow(
                    label: "淡出",
                    value: seg.effects.audioFadeOutDuration,
                    range: 0 ... max(0.1, seg.durationSeconds / 2),
                    format: { $0 < 0.05 ? "—" : String(format: "%.1fs", $0) },
                    onEdit: { document.setSelectedSegmentFade(fadeIn: nil, fadeOut: $0) }
                )
            })

            group("画面", content: {
                HStack(spacing: 10) {
                    inlineButton("旋转 \(seg.effects.rotation)°",
                                 systemName: "rotate.right") {
                        document.rotateSelectedSegment90()
                    }
                    inlineButton(seg.effects.flipHorizontal ? "水平 ✓" : "水平翻转",
                                 systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        document.flipSelectedSegmentHorizontal()
                    }
                }
                HStack(spacing: 10) {
                    inlineButton(seg.effects.flipVertical ? "垂直 ✓" : "垂直翻转",
                                 systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                        document.flipSelectedSegmentVertical()
                    }
                    Spacer()
                }
                divider
                sliderRow(
                    label: "亮度",
                    value: seg.effects.brightness,
                    range: -1 ... 1,
                    format: { String(format: "%+.2f", $0) },
                    onEdit: { document.setSelectedSegmentColor(brightness: $0) }
                )
                divider
                sliderRow(
                    label: "对比度",
                    value: seg.effects.contrast,
                    range: 0 ... 2,
                    format: { String(format: "%.2f", $0) },
                    onEdit: { document.setSelectedSegmentColor(contrast: $0) }
                )
                divider
                sliderRow(
                    label: "饱和度",
                    value: seg.effects.saturation,
                    range: 0 ... 2,
                    format: { String(format: "%.2f", $0) },
                    onEdit: { document.setSelectedSegmentColor(saturation: $0) }
                )
            })

            if let preset = document.visualEffects[seg.id], preset != .none {
                group("特效", content: {
                    readRow("预设", preset.label)
                })
            }

            if !seg.text.isEmpty || !seg.subtitles.isEmpty {
                group("文本", content: {
                    readRow("标题", seg.text.isEmpty ? "—" : seg.text)
                    divider
                    readRow("字幕条数", "\(seg.subtitles.count)")
                })
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(title))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.04))
                )
        }
    }

    private var divider: some View {
        Divider().background(Color.white.opacity(0.06))
    }

    @ViewBuilder
    private func readRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(L(label))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func sliderRow(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String,
        onEdit: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(L(label))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text(format(value))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Slider(
                value: Binding(get: { value }, set: { onEdit($0) }),
                in: range,
                onEditingChanged: { document.interactiveEdit($0) }
            )
            .tint(.white)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func inlineButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .medium))
                Text(L(title))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ s: Double) -> String {
        let total = max(0, s)
        let m = Int(total) / 60
        let sec = Int(total) % 60
        let frames = Int((total - floor(total)) * 30)
        return String(format: "%02d:%02d.%02d", m, sec, frames)
    }
}
