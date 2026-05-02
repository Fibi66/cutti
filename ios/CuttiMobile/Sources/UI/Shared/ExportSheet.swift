import SwiftUI
import CuttiKit

/// Modal shown when the user taps 导出. Picks resolution, kicks off
/// `IOSExportService`, shows progress, and dismisses after the file
/// is saved into Photos.
struct ExportSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    @State private var preset: IOSExportService.Preset = .p1080
    @State private var state: IOSExportService.Stage? = nil
    @State private var fraction: Float = 0
    @State private var startedAt: Date? = nil
    @State private var handle: IOSExportService.Handle? = nil
    @State private var shareURL: URL? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 24) {
                    if state == nil {
                        presetPicker
                        Spacer()
                        startButton
                    } else {
                        progressView
                    }
                }
                .padding(20)
            }
            .navigationTitle("导出视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(.white)
                        .disabled(state != nil && !isTerminal)
                }
            }
            .sheet(isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )) {
                if let url = shareURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分辨率")
                .font(.headline)
                .foregroundStyle(.white)
            HStack(spacing: 10) {
                ForEach([IOSExportService.Preset.p720, .p1080, .p4k], id: \.label) { p in
                    Button {
                        preset = p
                    } label: {
                        Text(p.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(p == preset ? .black : .white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(p == preset ? Color.white : Color.white.opacity(0.1))
                            )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var startButton: some View {
        Button {
            start()
        } label: {
            Text("开始导出")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0.95, green: 0.25, blue: 0.35))
                )
        }
    }

    private var progressView: some View {
        VStack(spacing: 16) {
            Spacer()
            if case .done = state {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                Text("已保存到相册")
                    .font(.headline)
                    .foregroundStyle(.white)
                if case .done(let url) = state {
                    Button {
                        shareURL = url
                    } label: {
                        Label("分享到其他应用", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.18))
                            )
                    }
                    .padding(.top, 8)
                }
            } else if case .failed(let msg) = state {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            } else {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.white)
                Text(stageLabel)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let elapsed = elapsedString {
                    Text(elapsed)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer()
            if isTerminal {
                Button("完成") { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.15))
                    )
            } else {
                Button {
                    handle?.cancel()
                } label: {
                    Text("取消导出")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.15))
                        )
                }
            }
        }
    }

    /// "已用 12s · 剩余 ~8s" — rough ETA from fraction + elapsed.
    private var elapsedString: String? {
        guard let startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        let elapsedTxt = String(format: "已用 %.0fs", elapsed)
        if fraction > 0.02 {
            let total = elapsed / Double(fraction)
            let remaining = max(0, total - elapsed)
            return elapsedTxt + String(format: " · 剩余 ~%.0fs", remaining)
        }
        return elapsedTxt
    }

    private var stageLabel: String {
        switch state {
        case .preparing: return "正在准备…"
        case .rendering: return "正在渲染…"
        case .saving:    return "正在保存到相册…"
        default: return ""
        }
    }

    private var isTerminal: Bool {
        if case .done = state { return true }
        if case .failed = state { return true }
        return false
    }

    private func start() {
        state = .preparing
        fraction = 0
        startedAt = Date()
        let h = IOSExportService.Handle()
        handle = h
        let coordinator = BackgroundExportCoordinator()
        coordinator.begin()
        Task {
            await IOSExportService.export(
                tracks: document.tracks,
                manifest: document.manifest,
                projectRoot: document.store.projectRoot,
                preset: preset,
                aspectRatio: document.aspectRatio,
                background: document.background,
                visualEffects: document.visualEffects,
                textOverlays: document.textOverlays + document.synthesizedSubtitleOverlays,
                transitions: document.transitions,
                chapters: document.chapters,
                handle: h
            ) { p in
                self.fraction = p.fraction
                self.state = p.stage
                switch p.stage {
                case .done:
                    coordinator.finish(success: true,
                                       title: "导出完成",
                                       body: "视频已保存到相册")
                case .failed(let msg):
                    coordinator.finish(success: false,
                                       title: "导出失败",
                                       body: msg)
                default: break
                }
            }
        }
    }
}
