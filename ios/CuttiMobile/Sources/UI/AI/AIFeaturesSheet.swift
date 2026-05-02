import SwiftUI
import CuttiKit

/// Bottom sheet listing every AI-powered preset as a one-tap shortcut
/// tile — mirrors `macOS/CuttiMac/.../AgentWorkflowPresets.swift`
/// (Smart cut / Speaker / Vision / Generative) plus an extra "iOS
/// native" group for the local-only Apple-API actions (SFSpeech TTS,
/// on-device voice enhancer, etc.).
///
/// Per user directive: "ios 不需要 ai 对话框，只需要把我 mac 预设的那些 ai
/// 功能设置成快捷键就可以了". So no chat composer — every action is a
/// direct button. Presets that still need the cloud LLM surface as
/// tiles with a visible `云端` badge and a toast saying they'll come
/// online once the iOS LLM runner lands.
///
/// Entry point is the "AI" pill on the left edge of `ToolDock`.
struct AIFeaturesSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    @State private var workingMessage: String?
    @State private var working: Bool = false
    @State private var presentTTS = false
    @State private var presentVoiceEnhance = false
    @State private var presentImageGen = false
    @State private var cloudResult: CloudResult?
    @State private var presentSignIn: Bool = false
    @State private var customLocaleDraft: String = ""
    @State private var presentCustomLocale: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heroCard
                    ForEach(Preset.Group.allCases) { group in
                        section(for: group)
                    }
                }
                .padding(.vertical, 14)
            }
            .overlay { if working { busyOverlay } }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("AI 工具箱")
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
        .sheet(isPresented: $presentTTS) {
            TextToSpeechSheet().environmentObject(document)
        }
        .sheet(isPresented: $presentVoiceEnhance) {
            AudioPicker(
                onPicked: { url in
                    presentVoiceEnhance = false
                    Task { await runVoiceEnhance(on: url) }
                },
                onCancel: { presentVoiceEnhance = false },
                includeVideo: true
            )
            .ignoresSafeArea()
        }
        .sheet(item: $cloudResult) { result in
            CloudResultSheet(title: result.title, text: result.body)
        }
        .sheet(isPresented: $presentImageGen) {
            ImageGenerationSheet { toast in
                presentImageGen = false
                flashToast(toast)
            }
        }
        .sheet(isPresented: $presentSignIn) {
            AccountAuthSheet(initialMode: .signIn)
                .presentationDetents([.medium, .large])
        }
        .alert(L("翻译目标语言"), isPresented: $presentCustomLocale) {
            TextField("e.g. ja / fr / es / zh-Hant", text: $customLocaleDraft)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button(L("翻译")) {
                let raw = customLocaleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                customLocaleDraft = ""
                if !raw.isEmpty {
                    runTranslateSubtitles(locale: raw, title: L("翻译字幕"))
                }
            }
            Button(L("取消"), role: .cancel) { customLocaleDraft = "" }
        } message: {
            Text(L("填写 BCP-47 语言代码,例如 ja / fr / es / zh-Hant"))
        }
    }

    // MARK: - Hero card

    /// Featured flagship action at the top of the sheet. Mirrors the
    /// CapCut "智能剪辑" hero banner pattern — one big, obviously-
    /// important entry point so new users don't have to scan a wall
    /// of tiles to find the marquee feature.
    @ViewBuilder
    private var heroCard: some View {
        if let hero = Preset.all.first(where: { $0.id == "smart.full" }) {
            Button {
                tap(hero)
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 52, height: 52)
                        Image(systemName: hero.icon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(hero.title)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        Text(hero.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.95))
                }
                .padding(16)
                .background(
                    LinearGradient(colors: [Color(red: 1.0, green: 0.32, blue: 0.45),
                                            Color(red: 1.0, green: 0.55, blue: 0.25)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(for group: Preset.Group) -> some View {
        // Hide smart.full from its section — it lives in the hero card above.
        let presets = Preset.all.filter { $0.group == group && $0.id != "smart.full" }
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: group.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(group.accent)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(group.accent.opacity(0.18))
                        )
                    Text(group.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(presets) { preset in
                            Button { tap(preset) } label: { tile(preset, accent: group.accent) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    /// Compact CapCut-style tile — icon-first, single-line title,
    /// optional corner badge. No subtitle crammed in; the label is
    /// exposed via accessibility hint so VoiceOver users still get
    /// the full description.
    private func tile(_ p: Preset, accent: Color) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(accent.opacity(0.18))
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(accent.opacity(0.25), lineWidth: 0.5)
                    )
                Image(systemName: p.icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 64, height: 64)
                if p.needsCloud {
                    Circle()
                        .fill(p.isCloudReady ? Color.green : Color.white.opacity(0.45))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                        .offset(x: 4, y: -4)
                }
            }
            Text(p.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 76)
        }
        .frame(width: 76)
        .accessibilityLabel(Text(p.title))
        .accessibilityHint(Text(p.subtitle))
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white).scaleEffect(1.3)
                if let m = workingMessage {
                    Text(m).font(.subheadline).foregroundStyle(.white)
                }
            }
        }
    }

    // MARK: - Dispatch

    private func tap(_ p: Preset) {
        switch p.action {
        case .autoSubtitles:       runAutoSubtitles()
        case .fillerWords:         runRemoveFillerWords()
        case .smartTransition:     runSmartTransition()
        case .introOutroFade:      runIntroOutroFade()
        case .textToSpeech:        presentTTS = true
        case .voiceEnhance:        presentVoiceEnhance = true
        case .pipSuggest:          runPiPSuggest()
        case .imageGen:            presentImageGen = true
        case .trimPauses:          runTrimPauses(p)
        case .transcriptCleanup:   runSmartCutWorkflow(p)
        case .translateSubtitles(let locale):
            runTranslateSubtitles(locale: locale, title: p.title)
        case .translateSubtitlesBilingualZhEn:
            runTranslateSubtitlesBilingualZhEn(title: p.title)
        case .translateSubtitlesCustom:
            customLocaleDraft = ""
            presentCustomLocale = true
        case .cloudPending(let hint):
            if p.id == "smart.full" {
                runSmartCutWorkflow(p)
            } else if IOSAIPresetRunner.supportedIDs.contains(p.id) {
                runCloudPreset(p)
            } else {
                flashToast("\(p.title) · \(hint)", dismissSheet: false)
            }
        }
    }

    /// Drives the smart.full (一键首剪) preset through
    /// `SmartCutWorkflow`, streaming per-phase progress into the busy
    /// overlay so the user sees which step is running
    /// (transcription / audio analysis / AI / applying). Structural
    /// parallel to the macOS `FullAnalysisPipeline` wiring in the
    /// editor shell.
    private func runSmartCutWorkflow(_ p: Preset) {
        working = true
        workingMessage = "\(p.title) · \(SmartCutWorkflow.Phase.transcribing.localizedDetail)"
        Task {
            do {
                let summary = try await SmartCutWorkflow.run(document: document) { progress in
                    Task { @MainActor in
                        workingMessage = "\(p.title) · \(progress.detail)"
                    }
                }
                await MainActor.run {
                    working = false
                    workingMessage = nil
                    let toast: String
                    if summary.cutCueCount == 0 && summary.keptCueCount > 0 {
                        toast = L("AI 觉得每一句都值得保留,没有删改")
                    } else if summary.keptCueCount == 0 {
                        toast = L("视频里没有可识别的语音,无法智能剪辑")
                    } else {
                        toast = String(
                            format: L("已智能裁掉 %lld 处,保留 %lld 句"),
                            summary.cutCueCount,
                            summary.keptCueCount
                        )
                    }
                    flashToast(toast)
                }
            } catch {
                await MainActor.run {
                    working = false
                    workingMessage = nil
                    if let e = error as? SmartCutWorkflow.Error,
                       case .notSignedIn = e {
                        presentSignIn = true
                    } else {
                        flashToast(error.localizedDescription, dismissSheet: false)
                    }
                }
            }
        }
    }

    /// One-shot cloud-relay call for transcript-only presets
    /// (summary, titles, chapters, B-roll, overlay titles). Text
    /// results land in `cloudResult` which presents a scrollable
    /// copy-enabled sheet; mutating presets (chapters) toast a
    /// summary instead and let the user see the change on the
    /// timeline.
    ///
    /// If the preset needs a transcript and none exists yet, we
    /// transparently run SFSpeech on the primary video first so the
    /// user doesn't have to manually tap 智能字幕 before every cloud
    /// tile. This mirrors the "just do it" behavior of CapCut's
    /// smart-cut button.
    private func runCloudPreset(_ p: Preset) {
        working = true
        workingMessage = "\(p.title) · 正在准备…"
        Task {
            do {
                if !IOSAIPresetRunner.localOnlyIDs.contains(p.id),
                   document.composedTranscriptCues.isEmpty {
                    try await autoTranscribePrimaryVideo()
                }
                await MainActor.run { workingMessage = "\(p.title) · 正在生成…" }
                let outcome = try await IOSAIPresetRunner.run(
                    presetID: p.id,
                    document: document
                )
                await MainActor.run {
                    working = false
                    workingMessage = nil
                    switch outcome {
                    case .text(let body):
                        cloudResult = CloudResult(title: p.title, body: body)
                    case .applied(let toast):
                        flashToast(toast)
                    }
                }
            } catch {
                await MainActor.run {
                    working = false
                    workingMessage = nil
                    // Auto-jump to sign-in when the runner reports no
                    // auth — saves the user from hunting for Settings
                    // after an error toast. We still flash a short
                    // explanation so they know why the form popped up.
                    if let e = error as? IOSAIPresetRunner.Error,
                       case .notSignedIn = e {
                        presentSignIn = true
                    } else {
                        flashToast(error.localizedDescription, dismissSheet: false)
                    }
                }
            }
        }
    }

    /// Local-only: trim silent spans via `AudioQualityService`.
    /// Mirrors macOS `smart.trimPauses` — scans the primary clip's
    /// audio, identifies silent ranges ≥ 0.5s, and splices them out
    /// of every timeline segment that references the same source.
    /// No transcription, no LLM, no credits consumed.
    private func runTrimPauses(_ p: Preset) {
        let target: (UUID, URL)? = {
            let seg: TimelineSegment? = document.selectedSegment
                ?? document.tracks.first(where: { $0.kind == .video })?.segments.first
            guard let segment = seg,
                  let media = document.manifest.media.first(where: { $0.id == segment.sourceVideoID })
            else { return nil }
            let root = document.store.projectRoot
            let url: URL = {
                if let rel = media.derived.proxyRelativePath {
                    let u = root.appending(path: rel)
                    if FileManager.default.fileExists(atPath: u.path) { return u }
                }
                return URL(fileURLWithPath: media.sourcePath)
            }()
            return (media.id, url)
        }()
        guard let (mediaID, url) = target else {
            flashToast(L("请先添加视频"), dismissSheet: false)
            return
        }

        working = true
        workingMessage = "\(p.title) · " + L("正在分析音频")
        Task {
            do {
                let service = AudioQualityService()
                let result = try await service.analyze(url: url)
                await MainActor.run {
                    let trimmed = document.trimSilentSourceRanges(
                        mediaID: mediaID,
                        sourceRanges: result.silentRanges,
                        minDurationSeconds: 0.5
                    )
                    working = false
                    workingMessage = nil
                    if trimmed == 0 {
                        flashToast(L("没有检测到需要裁剪的停顿"), dismissSheet: false)
                    } else {
                        flashToast(String(
                            format: L("已裁掉 %lld 处停顿"), trimmed
                        ))
                    }
                }
            } catch {
                await MainActor.run {
                    working = false
                    workingMessage = nil
                    flashToast(error.localizedDescription, dismissSheet: false)
                }
            }
        }
    }

    /// Translate every transcript cue to `locale` via the cloud LLM,
    /// write them onto `SubtitleEntry.translations[locale]`, and
    /// flip `transcriptDisplayLocale` so bilingual rendering turns
    /// on immediately. Mirrors macOS `subtitle.translate.*` semantics
    /// without routing through the chat agent.
    private func runTranslateSubtitles(locale: String, title: String) {
        working = true
        workingMessage = "\(title) · " + L("正在准备…")
        Task {
            do {
                if document.composedTranscriptCues.isEmpty {
                    try await autoTranscribePrimaryVideo()
                }
                let cues = await MainActor.run { document.composedTranscriptCues }
                guard !cues.isEmpty else {
                    throw NSError(
                        domain: "AIFeaturesSheet", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: L("没有字幕可翻译")]
                    )
                }
                let inputs = cues.map { SubtitleTranslator.Input(id: $0.id, text: $0.text) }
                await MainActor.run { workingMessage = "\(title) · " + L("正在翻译…") }
                let translations = try await SubtitleTranslator.translate(
                    cues: inputs, targetLocale: locale
                )
                await MainActor.run {
                    for (id, text) in translations {
                        document.setTranscriptCueTranslation(
                            id: id, locale: locale, text: text
                        )
                    }
                    document.transcriptDisplayLocale = locale
                    working = false
                    workingMessage = nil
                    flashToast(String(
                        format: L("已翻译 %lld 条字幕"), translations.count
                    ))
                }
            } catch {
                await MainActor.run {
                    working = false
                    workingMessage = nil
                    if let e = error as? SubtitleTranslator.Error,
                       case .notSignedIn = e {
                        presentSignIn = true
                    } else {
                        flashToast(error.localizedDescription, dismissSheet: false)
                    }
                }
            }
        }
    }

    /// Detect whether the current transcript is predominantly Chinese
    /// (CJK Unified Ideographs) — if so, translate every cue to
    /// English; otherwise translate every cue to Simplified Chinese.
    /// Matches macOS `SubtitlePrompts.bilingualZhEn`.
    private func runTranslateSubtitlesBilingualZhEn(title: String) {
        working = true
        workingMessage = "\(title) · " + L("正在准备…")
        Task {
            do {
                if document.composedTranscriptCues.isEmpty {
                    try await autoTranscribePrimaryVideo()
                }
                let cues = await MainActor.run { document.composedTranscriptCues }
                guard !cues.isEmpty else {
                    throw NSError(
                        domain: "AIFeaturesSheet", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: L("没有字幕可翻译")]
                    )
                }
                let targetLocale = Self.detectBilingualTargetLocale(cues: cues)
                await MainActor.run {
                    workingMessage = "\(title) · " + L("正在翻译…")
                }
                let inputs = cues.map { SubtitleTranslator.Input(id: $0.id, text: $0.text) }
                let translations = try await SubtitleTranslator.translate(
                    cues: inputs, targetLocale: targetLocale
                )
                await MainActor.run {
                    for (id, text) in translations {
                        document.setTranscriptCueTranslation(
                            id: id, locale: targetLocale, text: text
                        )
                    }
                    document.transcriptDisplayLocale = targetLocale
                    working = false
                    workingMessage = nil
                    flashToast(String(
                        format: L("已翻译 %lld 条字幕"), translations.count
                    ))
                }
            } catch {
                await MainActor.run {
                    working = false
                    workingMessage = nil
                    if let e = error as? SubtitleTranslator.Error,
                       case .notSignedIn = e {
                        presentSignIn = true
                    } else {
                        flashToast(error.localizedDescription, dismissSheet: false)
                    }
                }
            }
        }
    }

    /// Rough CJK-majority heuristic: if more than a quarter of the
    /// concatenated characters in the first handful of cues fall in
    /// the CJK Unified Ideographs block, we treat the transcript as
    /// Chinese and target English; otherwise target Simplified
    /// Chinese. Cheap, good enough for the bilingual preset.
    private static func detectBilingualTargetLocale<C: Collection>(cues: C) -> String
        where C.Element == ProjectDocument.TranscriptCue {
        let sample = cues.prefix(10).map { $0.text }.joined()
        let scalars = sample.unicodeScalars
        guard !scalars.isEmpty else { return "en" }
        let cjkCount = scalars.reduce(0) { acc, s in
            (0x4E00...0x9FFF).contains(Int(s.value)) ? acc + 1 : acc
        }
        return Double(cjkCount) / Double(scalars.count) > 0.25 ? "en" : "zh-Hans"
    }

    /// Transcribes the selected video (or the first video on the
    /// timeline) with SFSpeech and writes the cues onto the segment
    /// so subsequent cloud presets can read them via
    /// `document.composedTranscriptCues`. Throws if there is no
    /// importable video to transcribe.
    private func autoTranscribePrimaryVideo() async throws {
        let target: TimelineSegment? = await MainActor.run {
            if let s = document.selectedSegment { return s }
            return document.tracks.first(where: { $0.kind == .video })?.segments.first
        }
        guard let segment = target else {
            throw NSError(
                domain: "AIFeaturesSheet", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("请先添加视频")]
            )
        }
        let mediaAndURL: (MediaAssetRecord, URL)? = await MainActor.run {
            guard let media = document.manifest.media.first(where: { $0.id == segment.sourceVideoID }) else {
                return nil
            }
            let root = document.store.projectRoot
            let url: URL = {
                if let rel = media.derived.proxyRelativePath {
                    let u = root.appending(path: rel)
                    if FileManager.default.fileExists(atPath: u.path) { return u }
                }
                return URL(fileURLWithPath: media.sourcePath)
            }()
            return (media, url)
        }
        guard let (_, url) = mediaAndURL else {
            throw NSError(
                domain: "AIFeaturesSheet", code: 2,
                userInfo: [NSLocalizedDescriptionKey: L("找不到视频文件")]
            )
        }
        await MainActor.run { workingMessage = L("正在识别语音") }
        let entries = try await IOSTranscriber.transcribe(fileURL: url)
        await MainActor.run {
            document.setSubtitles(entries, forSegmentID: segment.id)
        }
    }

    // MARK: - Local actions

    private func runSmartTransition() {
        let applied = document.applyUniformTransition(seconds: 0.5)
        flashToast(applied > 0 ? "已为 \(applied) 处切点加入转场" : "时间线上没有可加转场的切点")
    }

    private func runIntroOutroFade() {
        let ok = document.applyIntroOutroFade(seconds: 0.8)
        flashToast(ok ? "已应用片头片尾淡入淡出" : "时间线为空")
    }

    private func runPiPSuggest() {
        let applied = document.applyPiPSuggestionsForOverlays()
        if applied == 0 {
            flashToast("没有可建议的画中画 — 添加 PiP 后再试", dismissSheet: false)
        } else {
            flashToast("已为 \(applied) 个画中画应用建议布局")
        }
    }

    private func runRemoveFillerWords() {
        let hasAnySubs = document.tracks
            .filter { $0.kind == .video }
            .flatMap { $0.segments }
            .contains { !$0.subtitles.isEmpty }
        if hasAnySubs {
            let removed = document.removeFillerWords()
            flashToast(removed > 0 ? "已去除 \(removed) 处口癖" : "未检测到口癖词")
            return
        }
        // Auto-transcribe first instead of forcing the user to tap
        // 智能字幕 manually — same UX guarantee as the cloud presets.
        working = true
        workingMessage = L("正在识别语音")
        Task {
            do {
                try await autoTranscribePrimaryVideo()
                await MainActor.run {
                    let removed = document.removeFillerWords()
                    working = false
                    workingMessage = nil
                    flashToast(removed > 0 ? "已去除 \(removed) 处口癖" : "未检测到口癖词")
                }
            } catch {
                await MainActor.run {
                    working = false
                    workingMessage = nil
                    flashToast(error.localizedDescription, dismissSheet: false)
                }
            }
        }
    }

    private func runAutoSubtitles() {
        let target: TimelineSegment? = {
            if let s = document.selectedSegment { return s }
            return document.tracks.first(where: { $0.kind == .video })?.segments.first
        }()
        guard let segment = target,
              let media = document.manifest.media.first(where: { $0.id == segment.sourceVideoID }) else {
            flashToast("请先添加视频", dismissSheet: false)
            return
        }
        let root = document.store.projectRoot
        let url: URL = {
            if let rel = media.derived.proxyRelativePath {
                let u = root.appending(path: rel)
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
            return URL(fileURLWithPath: media.sourcePath)
        }()

        working = true
        workingMessage = "正在识别语音"
        Task {
            do {
                let entries = try await IOSTranscriber.transcribe(fileURL: url)
                await MainActor.run {
                    document.setSubtitles(entries, forSegmentID: segment.id)
                    workingMessage = "完成，共 \(entries.count) 句"
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                await MainActor.run {
                    working = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    working = false
                    workingMessage = nil
                    flashToast("识别失败：\(error.localizedDescription)", dismissSheet: false)
                }
            }
        }
    }

    @MainActor
    private func runVoiceEnhance(on sourceURL: URL) async {
        working = true
        workingMessage = "正在增强人声…"
        defer {
            working = false
            workingMessage = nil
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceenh-\(UUID().uuidString).caf")
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try VoiceEnhancer.process(
                    sourceURL: sourceURL,
                    destinationURL: outURL,
                    settings: .defaultOn
                )
            }.value
            try await document.importAudio(at: outURL)
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: sourceURL)
            dismiss()
        } catch {
            workingMessage = "失败：\(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    // MARK: - Toast helper

    private func flashToast(_ text: String, dismissSheet: Bool = true) {
        working = true
        workingMessage = text
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                working = false
                workingMessage = nil
                if dismissSheet { dismiss() }
            }
        }
    }
}

// MARK: - Preset catalog

extension AIFeaturesSheet {
    struct Preset: Identifiable, Hashable {
        enum Action: Hashable {
            case autoSubtitles
            case fillerWords
            case smartTransition
            case introOutroFade
            case textToSpeech
            case voiceEnhance
            case pipSuggest
            case imageGen
            /// Local-only: trim silent spans via AudioQualityService.
            /// Matches macOS `smart.trimPauses` — no cloud, no credits.
            case trimPauses
            /// Cloud: full LLM-driven transcript cleanup. On iOS this
            /// is the same pipeline as `smart.full` because iOS has
            /// no B-roll suggestion pass to skip afterwards, but the
            /// tile is kept distinct for Mac parity.
            case transcriptCleanup
            /// Cloud: translate every cue to the given BCP-47 locale
            /// and enable bilingual display. Used by the subtitle
            /// presets with fixed targets (en / zh-Hans / bilingual).
            case translateSubtitles(locale: String)
            /// Cloud: detect current transcript language and translate
            /// to the "other" side (Chinese cues → English, everything
            /// else → Simplified Chinese). Matches macOS's
            /// `subtitle.bilingual.zh-en` behaviour.
            case translateSubtitlesBilingualZhEn
            /// Cloud: same as `translateSubtitles` but asks the user
            /// for the target locale first via a text alert.
            case translateSubtitlesCustom
            /// Tile shown, but backing runner isn't on iOS yet. The
            /// payload is a short hint surfaced in the toast so the
            /// user knows why it didn't fire.
            case cloudPending(String)
        }

        enum Group: String, CaseIterable, Identifiable {
            case smartCut, speaker, vision, generative, subtitles, native

            var id: String { rawValue }
            var title: String {
                switch self {
                case .smartCut:   return "智能剪辑"
                case .speaker:    return "说话人"
                case .vision:     return "画面分析"
                case .generative: return "生成创作"
                case .subtitles:  return "字幕翻译"
                case .native:     return "本机专属"
                }
            }

            /// SF Symbol shown in the circular chip next to the group
            /// title. Mirrors the CapCut AI panel's minimalist
            /// icon-per-section pattern.
            var icon: String {
                switch self {
                case .smartCut:   return "scissors"
                case .speaker:    return "person.2.wave.2"
                case .vision:     return "viewfinder"
                case .generative: return "sparkles"
                case .subtitles:  return "character.book.closed"
                case .native:     return "iphone.gen2"
                }
            }

            /// Single accent color per group — replaces the per-tile
            /// rainbow gradients so the sheet reads as one cohesive
            /// surface instead of 16 competing moods.
            var accent: Color {
                switch self {
                case .smartCut:   return Color(red: 1.0, green: 0.42, blue: 0.52)
                case .speaker:    return Color(red: 0.25, green: 0.78, blue: 0.90)
                case .vision:     return Color(red: 0.52, green: 0.58, blue: 1.00)
                case .generative: return Color(red: 1.0, green: 0.62, blue: 0.28)
                case .subtitles:  return Color(red: 0.88, green: 0.52, blue: 0.95)
                case .native:     return Color(red: 0.40, green: 0.82, blue: 0.60)
                }
            }
        }

        let id: String
        let group: Group
        let title: String
        let subtitle: String
        let icon: String
        let gradient: [Color]
        let action: Action

        var needsCloud: Bool {
            switch action {
            case .cloudPending, .transcriptCleanup,
                 .translateSubtitles, .translateSubtitlesBilingualZhEn,
                 .translateSubtitlesCustom:
                return true
            default:
                return false
            }
        }

        /// True when the preset needs the network AND we have a
        /// working iOS implementation. The tile still shows a 云端
        /// badge either way; the green/white dot just tells the user
        /// whether tapping will actually do something.
        ///
        /// `smart.full` is handled specially — its runner lives in
        /// `SmartCutWorkflow` (outside `IOSAIPresetRunner.supportedIDs`)
        /// but the tile is fully wired, so we green-dot it explicitly.
        var isCloudReady: Bool {
            guard needsCloud else { return false }
            switch action {
            case .transcriptCleanup,
                 .translateSubtitles, .translateSubtitlesBilingualZhEn,
                 .translateSubtitlesCustom:
                return true
            default:
                break
            }
            if id == "smart.full" { return true }
            return IOSAIPresetRunner.supportedIDs.contains(id)
        }

        static let all: [Preset] = [
            // MARK: Smart cut (mirrors macOS smart.* presets)
            .init(
                id: "smart.full",
                group: .smartCut,
                title: "一键首剪",
                subtitle: "按转写自动裁掉沉默、重复、半句",
                icon: "sparkles",
                gradient: [.pink, .orange],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),
            .init(
                id: "smart.fillers",
                group: .smartCut,
                title: "去除口癖",
                subtitle: "一键删除 uh / um / 嗯 / 那个",
                icon: "text.badge.minus",
                gradient: [.purple, .pink],
                action: .fillerWords
            ),
            .init(
                id: "smart.trimPauses",
                group: .smartCut,
                title: "仅去停顿",
                subtitle: "本地去掉沉默段,不动任何台词",
                icon: "waveform.path",
                gradient: [.pink, .red],
                action: .trimPauses
            ),
            .init(
                id: "smart.transcriptCleanup",
                group: .smartCut,
                title: "转写清理",
                subtitle: "AI 删除重复、换词、半截句子",
                icon: "text.badge.minus",
                gradient: [.red, .orange],
                action: .transcriptCleanup
            ),

            // MARK: Speaker (mirrors macOS speaker.* — all LLM)
            .init(
                id: "speaker.detect",
                group: .speaker,
                title: "识别说话人",
                subtitle: "按语义切分每位讲话者",
                icon: "person.2.wave.2",
                gradient: [.teal, .blue],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),
            .init(
                id: "speaker.mute",
                group: .speaker,
                title: "静音某位说话人",
                subtitle: "一键静音某人的全部台词",
                icon: "speaker.slash",
                gradient: [.indigo, .purple],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),
            .init(
                id: "speaker.list",
                group: .speaker,
                title: "提取某人台词",
                subtitle: "列出某位讲话者的所有句子",
                icon: "text.bubble",
                gradient: [.blue, .cyan],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),

            // MARK: Vision (mirrors macOS vision.*)
            .init(
                id: "vision.empty",
                group: .vision,
                title: "查找空镜",
                subtitle: "画面里没有人脸的区间",
                icon: "person.slash",
                gradient: [.gray, .black],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),
            .init(
                id: "vision.black",
                group: .vision,
                title: "查找黑场",
                subtitle: "接近黑画面或镜头被遮",
                icon: "square.fill",
                gradient: [.black, .gray],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),
            .init(
                id: "vision.autoPiP",
                group: .vision,
                title: "自动画中画",
                subtitle: "识别 presenter-cam 并按推荐布局放置",
                icon: "person.crop.circle.badge.checkmark",
                gradient: [.red, .orange],
                action: .pipSuggest
            ),

            // MARK: Generative (mirrors macOS gen.*)
            .init(
                id: "gen.broll",
                group: .generative,
                title: "B-Roll 建议",
                subtitle: "按语义推荐空镜插入点",
                icon: "sparkles.rectangle.stack",
                gradient: [.orange, .yellow],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),
            .init(
                id: "gen.title",
                group: .generative,
                title: "标题建议",
                subtitle: "按转写生成 3 条候选标题",
                icon: "text.cursor",
                gradient: [.mint, .teal],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),
            .init(
                id: "gen.chapters",
                group: .generative,
                title: "章节自动切分",
                subtitle: "AI 根据内容划分章节并生成进度条",
                icon: "list.bullet.rectangle",
                gradient: [.purple, .indigo],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),
            .init(
                id: "gen.overlayTitles",
                group: .generative,
                title: "动效标题卡",
                subtitle: "在强调段落插入 ChapterTitle 动画卡",
                icon: "sparkles.tv",
                gradient: [.pink, .purple],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),
            .init(
                id: "gen.image",
                group: .generative,
                title: "生成 AI 图像",
                subtitle: "描述一张图片 · 生成后保存到相册",
                icon: "photo.badge.plus",
                gradient: [.cyan, .blue],
                action: .imageGen
            ),
            .init(
                id: "gen.summary",
                group: .generative,
                title: "视频摘要",
                subtitle: "一段话概括视频内容",
                icon: "doc.text.magnifyingglass",
                gradient: [.yellow, .orange],
                action: .cloudPending("需要云端 LLM · 即将开放")
            ),

            // MARK: Subtitles (mirrors macOS subtitle.* presets)
            .init(
                id: "subtitle.bilingual.zh-en",
                group: .subtitles,
                title: "中英双语字幕",
                subtitle: "自动在中文和英文之间互译并双语显示",
                icon: "character.bubble",
                gradient: [.pink, .purple],
                action: .translateSubtitlesBilingualZhEn
            ),
            .init(
                id: "subtitle.translate.en",
                group: .subtitles,
                title: "添加英文译文",
                subtitle: "翻译每条字幕为英文并开启双语显示",
                icon: "text.badge.plus",
                gradient: [.blue, .purple],
                action: .translateSubtitles(locale: "en")
            ),
            .init(
                id: "subtitle.translate.zh",
                group: .subtitles,
                title: "添加中文译文",
                subtitle: "翻译每条字幕为中文并开启双语显示",
                icon: "text.badge.plus",
                gradient: [.purple, .pink],
                action: .translateSubtitles(locale: "zh-Hans")
            ),
            .init(
                id: "subtitle.translate.custom",
                group: .subtitles,
                title: "翻译到其他语言…",
                subtitle: "填写目标语言代码,AI 翻译并双语显示",
                icon: "globe",
                gradient: [.indigo, .purple],
                action: .translateSubtitlesCustom
            ),

            // MARK: Native (iOS-only, local models)
            .init(
                id: "native.subs",
                group: .native,
                title: "智能字幕",
                subtitle: "SFSpeech 本机识别 · 零依赖",
                icon: "captions.bubble",
                gradient: [.blue, .cyan],
                action: .autoSubtitles
            ),
            .init(
                id: "native.transition",
                group: .native,
                title: "一键转场",
                subtitle: "给所有切点加入平滑转场",
                icon: "arrow.triangle.swap",
                gradient: [.cyan, .indigo],
                action: .smartTransition
            ),
            .init(
                id: "native.openEnd",
                group: .native,
                title: "片头片尾淡入淡出",
                subtitle: "自动为首尾加入缓入缓出",
                icon: "play.rectangle",
                gradient: [.blue, .purple],
                action: .introOutroFade
            ),
            .init(
                id: "native.tts",
                group: .native,
                title: "文本转语音",
                subtitle: "Apple TTS 本机合成旁白",
                icon: "speaker.wave.2.bubble",
                gradient: [.green, .teal],
                action: .textToSpeech
            ),
            .init(
                id: "native.voiceEnhance",
                group: .native,
                title: "人声增强",
                subtitle: "高通 + 动态 + 限幅 · 本机离线",
                icon: "waveform.badge.mic",
                gradient: [.indigo, .purple],
                action: .voiceEnhance
            ),
        ]
    }
}

// MARK: - Cloud result sheet

extension AIFeaturesSheet {
    struct CloudResult: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }
}

private struct CloudResultSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }
}
