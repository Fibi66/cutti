import SwiftUI
import CuttiKit

/// iPad-native two-pane layout for landscape + larger portrait:
///   topBar                                           (shared)
///   ┌────────────────────────────┬────────────────┐
///   │ Preview                    │ Segment        │
///   │                            │ Inspector      │
///   │ TransportBar               │ (read-only)    │
///   └────────────────────────────┴────────────────┘
///   TimelineCanvas  (full width, taller than phone)
///   ToolDock        (full width)
///
/// Narrow iPad multitasking windows fall back to the phone layout.
struct EditorPadLayout: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var document: ProjectDocument
    @State private var showPicker = false
    @State private var pickerMode: PadPickerMode = .primary
    @State private var importError: String?
    @State private var showAISheet = false
    @State private var showExport = false
    @State private var pendingTrimURL: URL?

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 820 {
                EditorPhoneLayout()
            } else {
                padBody
            }
        }
    }

    private var padBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        PreviewPane()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        TransportBar()
                    }
                    .frame(maxWidth: .infinity)
                    Divider().background(Color.white.opacity(0.08))
                    SegmentInspectorPanel()
                        .frame(width: 320)
                }
                .frame(maxHeight: .infinity)
                TimelineCanvas()
                    .frame(height: 180)
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
            get: { pendingTrimURL.map(PadTrimURL.init) },
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
        HStack(spacing: 12) {
            Button { appState.closeProject() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            Button { showPicker = true } label: {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            Button { document.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(document.canUndo ? 1 : 0.35))
                    .frame(width: 36, height: 36)
            }
            .disabled(!document.canUndo)
            Button { document.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(document.canRedo ? 1 : 0.35))
                    .frame(width: 36, height: 36)
            }
            .disabled(!document.canRedo)
            Text(document.project.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer()
            Button { document.toggleShowSubtitles() } label: {
                Image(systemName: document.showSubtitles ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
            Button { showExport = true } label: {
                HStack(spacing: 4) {
                    Text("1080P").font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
            }
            Button { showExport = true } label: {
                Text("导出")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.95, green: 0.25, blue: 0.35))
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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

private enum PadPickerMode {
    case primary
    case pip
}

private struct PadTrimURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
