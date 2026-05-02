import SwiftUI
import CuttiKit

/// Bottom sheet for adjusting the selected segment's volume level.
struct VolumeAdjustSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let level = Binding<Double>(
            get: { document.selectedSegment?.volumeLevel ?? 1.0 },
            set: { document.setSelectedSegmentVolume($0) }
        )

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("音量")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.0f%%", level.wrappedValue * 100))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.slash")
                    .foregroundStyle(.white.opacity(0.6))
                Slider(value: level, in: 0...1,
                       onEditingChanged: { document.interactiveEdit($0) })
                    .tint(.white)
                Image(systemName: "speaker.wave.3")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
    }
}

/// Bottom sheet for adjusting the selected segment's playback speed.
struct SpeedAdjustSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    private let presets: [Double] = [0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0]

    var body: some View {
        let rate = Binding<Double>(
            get: { document.selectedSegment?.speedRate ?? 1.0 },
            set: { document.setSelectedSegmentSpeed($0) }
        )

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("变速")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.2fx", rate.wrappedValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                Button { dismiss() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
            }
            Slider(
                value: rate,
                in: TimelineSegment.minimumSpeedRate...TimelineSegment.maximumSpeedRate,
                onEditingChanged: { document.interactiveEdit($0) }
            )
            .tint(.white)
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { p in
                    Button {
                        document.setSelectedSegmentSpeed(p)
                    } label: {
                        Text(String(format: p == floor(p) ? "%.0fx" : "%.2gx", p))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(abs(p - rate.wrappedValue) < 0.01
                                        ? Color.white.opacity(0.3)
                                        : Color.white.opacity(0.1))
                            )
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
    }
}

/// Bottom sheet for brightness / contrast / saturation on the
/// selected segment. Binds directly into `ProjectDocument` so every
/// slider drag is a real (undoable) edit.
struct ColorAdjustSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let effects = document.selectedSegment?.effects ?? .default
        let brightness = Binding(
            get: { effects.brightness },
            set: { document.setSelectedSegmentColor(brightness: $0) }
        )
        let contrast = Binding(
            get: { effects.contrast },
            set: { document.setSelectedSegmentColor(contrast: $0) }
        )
        let saturation = Binding(
            get: { effects.saturation },
            set: { document.setSelectedSegmentColor(saturation: $0) }
        )

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("色彩调节").font(.headline).foregroundStyle(.white)
                Spacer()
                Button("重置") { document.resetSelectedSegmentEffects() }
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                Button { dismiss() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
            }
            sliderRow("亮度", binding: brightness, range: -1...1, center: 0)
            sliderRow("对比度", binding: contrast, range: 0...2, center: 1)
            sliderRow("饱和度", binding: saturation, range: 0...2, center: 1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private func sliderRow(_ label: String, binding: Binding<Double>,
                           range: ClosedRange<Double>, center: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L(label)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(String(format: "%+.2f", binding.wrappedValue - center))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: binding, in: range,
                   onEditingChanged: { document.interactiveEdit($0) }).tint(.white)
        }
    }
}

/// Bottom sheet for adding a new text/caption cue at the current
/// playhead. The cue is inserted into whichever primary segment the
/// playhead is over. Duration defaults to 2 seconds.
struct AddTextSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var duration: Double = 2.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("添加文本").font(.headline).foregroundStyle(.white)
                Spacer()
                Button("取消") { dismiss() }
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                Button {
                    _ = document.insertTextAtPlayhead(text, duration: duration)
                    dismiss()
                } label: {
                    Text("添加").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 0.95, green: 0.25, blue: 0.35)))
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            }
            TextField("", text: $text, prompt: Text("输入文本…").foregroundStyle(.white.opacity(0.4)),
                      axis: .vertical)
                .lineLimit(3...5)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.08))
                )
            HStack {
                Text("时长").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                Slider(value: $duration, in: 0.5...10).tint(.white)
                Text(String(format: "%.1fs", duration))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
    }
}

/// Bottom sheet for editing the project-wide subtitle style (font
/// size, color, background, vertical position, alignment). Applies
/// live to the CC overlay in `PreviewPane`.
struct TextStyleSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    private let fontSizes: [Double] = [36, 48, 64, 80, 96, 120]
    private let palette: [SubtitleStyle.RGBAColor] = [
        .white, .yellow,
        .init(red: 0.2, green: 0.8, blue: 1.0, alpha: 1),   // cyan
        .init(red: 1.0, green: 0.35, blue: 0.45, alpha: 1), // pink
        .init(red: 0.55, green: 0.95, blue: 0.3, alpha: 1), // green
        .black
    ]

    var body: some View {
        let s = document.subtitleStyle
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("字幕样式").font(.headline).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
            }

            // Font size
            VStack(alignment: .leading, spacing: 6) {
                Text("字号").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 8) {
                    ForEach(fontSizes, id: \.self) { size in
                        Button {
                            document.updateSubtitleStyle { $0.fontSizePoints = size }
                        } label: {
                            Text("\(Int(size))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(minWidth: 36, minHeight: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(abs(s.fontSizePoints - size) < 1
                                              ? Color.white.opacity(0.3)
                                              : Color.white.opacity(0.1))
                                )
                        }
                    }
                }
            }

            // Text color
            VStack(alignment: .leading, spacing: 6) {
                Text("颜色").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 10) {
                    ForEach(palette.indices, id: \.self) { i in
                        let c = palette[i]
                        Button {
                            document.updateSubtitleStyle { $0.textColor = c }
                        } label: {
                            Circle()
                                .fill(Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.white, lineWidth: isEq(c, s.textColor) ? 2 : 0))
                        }
                    }
                }
            }

            // Background
            VStack(alignment: .leading, spacing: 6) {
                Text("背景透明度").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                Slider(
                    value: Binding(
                        get: { s.backgroundColor.alpha },
                        set: { a in
                            document.updateSubtitleStyle {
                                $0.backgroundColor = SubtitleStyle.RGBAColor(
                                    red: $0.backgroundColor.red,
                                    green: $0.backgroundColor.green,
                                    blue: $0.backgroundColor.blue,
                                    alpha: a
                                )
                            }
                        }
                    ), in: 0...1,
                    onEditingChanged: { document.interactiveEdit($0) }
                ).tint(.white)
            }

            // Vertical position
            VStack(alignment: .leading, spacing: 6) {
                Text(L("垂直位置 %lld%%", Int(s.verticalPositionFraction * 100)))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                Slider(
                    value: Binding(
                        get: { s.verticalPositionFraction },
                        set: { v in document.updateSubtitleStyle { $0.verticalPositionFraction = v } }
                    ),
                    in: 0...1,
                    onEditingChanged: { document.interactiveEdit($0) }
                ).tint(.white)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
    }

    private func isEq(_ a: SubtitleStyle.RGBAColor, _ b: SubtitleStyle.RGBAColor) -> Bool {
        abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01 && abs(a.blue - b.blue) < 0.01
    }
}

/// Bottom sheet for setting audio fade-in / fade-out durations on
/// the selected segment. Both respected at preview time and at export.
struct FadeAdjustSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let seg = document.selectedSegment
        let maxFade = min(5.0, (seg?.durationSeconds ?? 1) / 2)
        let fadeIn = Binding<Double>(
            get: { seg?.effects.audioFadeInDuration ?? 0 },
            set: { document.setSelectedSegmentFade(fadeIn: $0) }
        )
        let fadeOut = Binding<Double>(
            get: { seg?.effects.audioFadeOutDuration ?? 0 },
            set: { document.setSelectedSegmentFade(fadeOut: $0) }
        )

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("淡入淡出").font(.headline).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("淡入").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.1fs", fadeIn.wrappedValue))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Slider(value: fadeIn, in: 0...maxFade,
                       onEditingChanged: { document.interactiveEdit($0) }).tint(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("淡出").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.1fs", fadeOut.wrappedValue))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Slider(value: fadeOut, in: 0...maxFade,
                       onEditingChanged: { document.interactiveEdit($0) }).tint(.white)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
    }
}
