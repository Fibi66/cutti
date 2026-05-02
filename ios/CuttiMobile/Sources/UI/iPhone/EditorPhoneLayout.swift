import SwiftUI
import CuttiKit

/// CapCut-style iPhone layout, top-to-bottom:
///   top bar   : X · 1080P · 导出
///   preview   : flexible, black background
///   transport : compact row (time · play · cut/undo/redo/fullscreen)
///   timeline  : scrollable, no lane labels, thumbnail clips
///   tool dock : 剪辑 / 音频 / 文本 / 贴纸 / 画中画 / 特效 …
struct EditorPhoneLayout: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var document: ProjectDocument
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showPicker = false
    /// Distinguishes a regular timeline import from a "添加画中画" PiP
    /// import so the picker callback can route to the correct document
    /// method. Reset to `.primary` after each sheet round-trip.
    @State private var pickerMode: PickerMode = .primary
    @State private var importError: String?
    @State private var showAISheet = false
    @State private var showExport = false
    @State private var showFullscreen = false
    /// URL of the picked but not-yet-imported video. When non-nil we
    /// surface the trim preview sheet before handing the file to the
    /// importer; nil outside the picker→trim→import flow.
    @State private var pendingTrimURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                PreviewPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TransportBar()
                TimelineCanvas()
                    .frame(height: 180)
                    .clipped()
                ToolDock(onAITapped: { showAISheet = true })
            }
            KeyboardShortcutsLayer()
        }
        .sheet(isPresented: $showPicker) {
            VideoPicker(
                onPicked: { url in
                    showPicker = false
                    if pickerMode == .pip {
                        Task { await runPiPImport(url: url) }
                        pickerMode = .primary
                    } else {
                        pendingTrimURL = url
                    }
                },
                onCancel: {
                    showPicker = false
                    pickerMode = .primary
                }
            )
            .ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cuttiRequestMediaImport)) { _ in
            pickerMode = .primary
            showPicker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cuttiRequestPiPImport)) { _ in
            pickerMode = .pip
            showPicker = true
        }
        .sheet(item: Binding(
            get: { pendingTrimURL.map(TrimURL.init) },
            set: { if $0 == nil { pendingTrimURL = nil } }
        )) { wrapper in
            TrimPreviewSheet(sourceURL: wrapper.url) { range in
                let url = wrapper.url
                pendingTrimURL = nil
                if let range {
                    Task { await runImport(url: url, range: range) }
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showAISheet) {
            AIFeaturesSheet()
                .environmentObject(document)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showExport) {
            ExportSheet()
                .environmentObject(document)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            FullscreenPreview()
                .environmentObject(document)
                .environmentObject(appState)
        }
        .onAppear {
            if verticalSizeClass == .compact && !showFullscreen {
                showFullscreen = true
            }
        }
        .onChange(of: verticalSizeClass) { _, newValue in
            // iPhone landscape → compact vertical size class. Auto-enter
            // the immersive preview so the editor UI doesn't get
            // crushed into a sliver. Returning to portrait (regular)
            // dismisses it.
            if newValue == .compact {
                if !showFullscreen { showFullscreen = true }
            } else {
                if showFullscreen { showFullscreen = false }
            }
        }
        .alert(
            "导入失败",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(importError ?? "") }
        )
    }

    private var topBar: some View {
        // Match CapCut exactly:
        //   X  🔍              [💎使用中]  1080P▼   [💎导出]
        // The Pro-badge pill and resolution caret sit to the right of
        // the leading icon cluster; the red Export pill hugs the
        // trailing edge. No undo/redo/CC here — those live on the
        // transport row / sub-sheets, matching the reference.
        HStack(spacing: 14) {
            Button {
                appState.closeProject()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
            }

            Button {
                // Search placeholder — surfaces a future project/media
                // search sheet. Wired silently for now so the icon
                // matches CapCut's leading cluster.
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
            }

            Spacer(minLength: 0)

            // 💎 使用中 pro-status pill (dark translucent chip)
            HStack(spacing: 4) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.38, blue: 0.46))
                Text("使用中")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.10))
            )

            // 1080P ▼ — plain text button, no background. Taps open
            // the export sheet where resolution can be changed.
            Button { showExport = true } label: {
                HStack(spacing: 3) {
                    Text("1080P")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }

            // 💎 导出 red action pill.
            Button { showExport = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                    Text("导出")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.98, green: 0.28, blue: 0.38))
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.black)
    }

    private func runImport(url: URL, range: ClosedRange<Double>? = nil) async {
        do {
            let tr = range.map { CuttiKit.TimeRange(startSeconds: $0.lowerBound, endSeconds: $0.upperBound) }
            try await document.importVideo(at: url, initialRange: tr)
            try? FileManager.default.removeItem(at: url)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func runPiPImport(url: URL) async {
        do {
            try await document.importPiPOverlay(at: url)
            try? FileManager.default.removeItem(at: url)
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// Distinguishes a regular primary-track import from a PiP overlay
/// import so `VideoPicker` callbacks can route the picked URL to the
/// correct `ProjectDocument` method.
private enum PickerMode {
    case primary
    case pip
}

/// Identifiable wrapper so `.sheet(item:)` can drive TrimPreviewSheet
/// off the optional URL state. URL itself is Identifiable only via
/// absoluteString; a struct keeps intent explicit.
private struct TrimURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
