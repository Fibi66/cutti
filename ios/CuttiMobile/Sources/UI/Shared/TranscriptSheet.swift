import SwiftUI
import UniformTypeIdentifiers
import CuttiKit

/// Descript-style transcript editor for iOS. Lists every cue across the
/// primary track in composed-time order; tap a row to seek, tap the
/// text to edit inline, swipe to delete (which excises the
/// corresponding source-media interval from the timeline so the cut
/// follows the words).
///
/// Companion to the macOS `TranscriptView`. Intentionally simpler —
/// no speaker diarization, no tombstones, no multi-select. Find /
/// replace + SRT/VTT export + bulk transcribe round out the feature.
struct TranscriptSheet: View {
    @EnvironmentObject private var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var caseSensitive: Bool = false
    @State private var showFindBar: Bool = false
    @State private var statusMessage: String?
    @State private var transcribing: Bool = false
    @State private var editingCueID: UUID?
    @State private var draftText: String = ""
    @State private var sharePayload: SharePayload?
    @State private var editingTranslationCueID: UUID?
    @State private var draftTranslation: String = ""
    @State private var presentImporter: Bool = false

    private static let bilingualLocales: [(label: String, code: String)] = [
        ("中文 (简)", "zh-Hans"),
        ("中文 (繁)", "zh-Hant"),
        ("English", "en"),
        ("日本語", "ja"),
        ("한국어", "ko"),
        ("Español", "es"),
        ("Français", "fr"),
        ("Deutsch", "de"),
    ]

    private struct SharePayload: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                content
                if transcribing {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text(statusMessage ?? "正在识别…")
                            .font(.callout)
                            .foregroundStyle(.white)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .navigationTitle("字幕编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showFindBar.toggle()
                        } label: {
                            Label(showFindBar ? "隐藏查找" : "查找替换",
                                  systemImage: "magnifyingglass")
                        }
                        Button {
                            Task { await runTranscribeAll() }
                        } label: {
                            Label("识别全部", systemImage: "waveform.badge.mic")
                        }
                        Menu {
                            Button {
                                document.transcriptDisplayLocale = nil
                            } label: {
                                if document.transcriptDisplayLocale == nil {
                                    Label("关闭双语", systemImage: "checkmark")
                                } else {
                                    Text("关闭双语")
                                }
                            }
                            Divider()
                            ForEach(Self.bilingualLocales, id: \.code) { item in
                                Button {
                                    document.transcriptDisplayLocale = item.code
                                } label: {
                                    if document.transcriptDisplayLocale == item.code {
                                        Label(item.label, systemImage: "checkmark")
                                    } else {
                                        Text(item.label)
                                    }
                                }
                            }
                        } label: {
                            Label("双语显示", systemImage: "character.book.closed")
                        }
                        Divider()
                        Button { presentImporter = true } label: {
                            Label("导入字幕", systemImage: "square.and.arrow.down")
                        }
                        Button { exportSubtitles(.srt) } label: {
                            Label("导出 SRT", systemImage: "square.and.arrow.up")
                        }
                        Button { exportSubtitles(.vtt) } label: {
                            Label("导出 VTT", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.urls)
            }
            .fileImporter(
                isPresented: $presentImporter,
                allowedContentTypes: Self.importerTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let cues = document.composedTranscriptCues
        VStack(spacing: 0) {
            if showFindBar { findBar }
            if let msg = statusMessage, !transcribing {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            if cues.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(cues) { cue in
                        cueRow(cue)
                            .listRowBackground(rowBackground(for: cue))
                    }
                    .onDelete { idx in
                        let toDelete = idx.map { cues[$0].id }
                        for id in toDelete { document.deleteTranscriptCue(id: id) }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("还没有字幕")
                .font(.headline)
            Text("点击右上角 「识别全部」 开始转写。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await runTranscribeAll() }
            } label: {
                Label("识别全部", systemImage: "waveform.badge.mic")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cueRow(_ cue: ProjectDocument.TranscriptCue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    document.seek(toSeconds: cue.composedStart)
                } label: {
                    Text(timecode(cue.composedStart))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.pink)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(String(format: "%.1fs", max(0, cue.composedEnd - cue.composedStart)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if editingCueID == cue.id {
                TextField("字幕文本", text: $draftText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit { commitEdit(for: cue.id) }
                HStack {
                    Spacer()
                    Button("取消") {
                        editingCueID = nil
                        draftText = ""
                    }
                    .buttonStyle(.bordered)
                    Button("保存") { commitEdit(for: cue.id) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Text(cue.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draftText = cue.text
                        editingCueID = cue.id
                    }
            }
            if let locale = document.transcriptDisplayLocale {
                translationRow(for: cue, locale: locale)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func translationRow(for cue: ProjectDocument.TranscriptCue,
                                locale: String) -> some View {
        if editingTranslationCueID == cue.id {
            VStack(alignment: .leading, spacing: 6) {
                TextField(L("译文 (%@)", locale), text: $draftTranslation, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                HStack {
                    Spacer()
                    Button("取消") {
                        editingTranslationCueID = nil
                        draftTranslation = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("保存") {
                        document.setTranscriptCueTranslation(
                            id: cue.id,
                            locale: locale,
                            text: draftTranslation
                        )
                        editingTranslationCueID = nil
                        draftTranslation = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "character.book.closed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let translated = cue.translations[locale], !translated.isEmpty {
                    Text(translated)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("添加译文")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                draftTranslation = cue.translations[locale] ?? ""
                editingTranslationCueID = cue.id
            }
        }
    }

    private func rowBackground(for cue: ProjectDocument.TranscriptCue) -> Color {
        let t = document.currentTime
        if t >= cue.composedStart && t <= cue.composedEnd {
            return Color.pink.opacity(0.12)
        }
        return Color.clear
    }

    // MARK: - Find/Replace

    private var findBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找", text: $findText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("替换为", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                Toggle("Aa", isOn: $caseSensitive)
                    .toggleStyle(.button)
                    .controlSize(.small)
                Button {
                    let n = document.replaceInTranscript(
                        find: findText,
                        replace: replaceText,
                        caseSensitive: caseSensitive
                    )
                    statusMessage = n > 0 ? "已替换 \(n) 处" : "没有匹配项"
                } label: {
                    Text("替换")
                }
                .buttonStyle(.borderedProminent)
                .disabled(findText.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Actions

    private func commitEdit(for id: UUID) {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        document.updateTranscriptCueText(id: id, newText: trimmed)
        editingCueID = nil
        draftText = ""
    }

    private func runTranscribeAll() async {
        transcribing = true
        statusMessage = "正在识别全部片段…"
        let added = await document.transcribeAllPrimarySegments()
        transcribing = false
        statusMessage = added > 0 ? "完成，共新增 \(added) 句" : "没有可识别的片段"
    }

    private enum Format { case srt, vtt }

    private func exportSubtitles(_ format: Format) {
        let body: String
        let ext: String
        switch format {
        case .srt:
            body = document.subtitlesSRT()
            ext = "srt"
        case .vtt:
            body = document.subtitlesVTT()
            ext = "vtt"
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "还没有字幕，无法导出"
            return
        }
        let name = "transcript-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try body.data(using: .utf8)?.write(to: url, options: .atomic)
            sharePayload = SharePayload(urls: [url])
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        let sec = Int(s) % 60
        let ms = Int((s - floor(s)) * 100)
        if h > 0 {
            return String(format: "%d:%02d:%02d.%02d", h, m, sec, ms)
        }
        return String(format: "%d:%02d.%02d", m, sec, ms)
    }

    // MARK: - Import

    /// Allowed content types for the subtitle importer. Handles the
    /// three common sources: explicit `.srt`/`.vtt` UTIs when the
    /// system has them registered, plus plain text for files that
    /// iOS hasn't typed yet.
    private static var importerTypes: [UTType] {
        var out: [UTType] = [.plainText, .text]
        if let t = UTType(filenameExtension: "srt") { out.append(t) }
        if let t = UTType(filenameExtension: "vtt") { out.append(t) }
        return out
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            statusMessage = "导入失败：\(err.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let count = try document.importSubtitles(fromFile: url)
                statusMessage = count > 0
                    ? "已导入 \(count) 条字幕"
                    : "未匹配到任何片段"
            } catch {
                statusMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}
