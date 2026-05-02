import Foundation
import CuttiKit

/// iOS counterpart to the macOS `FullAnalysisPipeline` — orchestrates
/// the individual AI features (transcription → audio silence scan →
/// LLM edit decision → timeline mutation) into a single "一键首剪"
/// workflow.
///
/// Each phase delegates to a reusable service so the same building
/// blocks power both the individual AI tiles (智能字幕, 去除口癖, …)
/// and this one-click composite:
///
///   1. `IOSTranscriber.transcribe`        — SFSpeech on-device recognition
///   2. `AudioQualityService.analyze`      — PCM silence detection (parallel)
///   3. `LLMEditorService.selectSegments`  — cloud keep/cut decision
///   4. `ProjectDocument.removeCues`       — apply the cuts
///
/// Mirrors the layout of `FullAnalysisPipeline.swift` (macOS) so the
/// two platforms stay structurally aligned. If we later share more
/// of the pipeline via CuttiKit, this file is the natural seam.
enum SmartCutWorkflow {

    // MARK: - Progress reporting

    /// Phase labels mirror the user-facing strings in macOS's
    /// `MediaCoreViewModel.updateAnalysisChatBubble` so the two
    /// platforms describe the workflow identically. macOS has no
    /// explicit "applying" phase (it produces suggestions the user
    /// accepts later), so we don't either — the cuts are committed
    /// as part of the final step and a single completion toast is
    /// surfaced.
    enum Phase: String, Sendable {
        case transcribing
        case analyzingAudio
        case requestingAI
        case complete

        var localizedDetail: String {
            switch self {
            case .transcribing:   return L("正在识别语音")
            case .analyzingAudio: return L("正在分析音频")
            case .requestingAI:   return L("AI 正在规划剪辑")
            case .complete:       return L("本地分析完成")
            }
        }
    }

    struct Progress: Sendable {
        let phase: Phase
        let fractionComplete: Double
        let detail: String
    }

    struct Summary: Sendable {
        let keptCueCount: Int
        let cutCueCount: Int
        let longSilenceCount: Int
    }

    // MARK: - Errors

    enum Error: Swift.Error, LocalizedError {
        case notSignedIn
        case noVideo
        case transcriptionFailed(String)
        case llmFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return L("请先登录 Cutti 账号以调用云端 AI。")
            case .noVideo:
                return L("请先添加视频")
            case .transcriptionFailed(let m):
                return L("语音识别失败：") + m
            case .llmFailed(let m):
                return L("AI 剪辑失败：") + m
            }
        }
    }

    // MARK: - Entry point

    /// Runs the full first-cut workflow against the document's
    /// primary (or selected) video segment. Emits granular progress
    /// so the caller can update a busy overlay per phase.
    ///
    /// - Parameter document: edited in place — transcript cues are
    ///   written onto the segment, then non-keep cues are removed.
    /// - Parameter onProgress: invoked on phase transitions. The
    ///   caller is responsible for hopping to the main actor if it
    ///   touches UI.
    /// - Returns: `Summary` describing how many cues were kept/cut
    ///   and how many long silences (>1s) were detected inside the
    ///   kept range for informational reporting.
    @MainActor
    static func run(
        document: ProjectDocument,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> Summary {
        // Guard: auth + video presence.
        let token = RelaySession.currentBearerToken() ?? ""
        guard !token.isEmpty else { throw Error.notSignedIn }

        guard let segment = primaryTargetSegment(in: document),
              let media = document.manifest.media.first(where: { $0.id == segment.sourceVideoID })
        else {
            throw Error.noVideo
        }

        let sourceURL = resolveURL(for: media, root: document.store.projectRoot)
        let segmentID = segment.id

        // ============ Step 1 + Step 2 (parallel) ============
        // Speech recognition and audio silence detection are both
        // I/O-bound scans of the source file — kick them off
        // concurrently like AnalysisOrchestrator does on macOS.
        onProgress(Progress(
            phase: .transcribing,
            fractionComplete: 0.05,
            detail: Phase.transcribing.localizedDetail
        ))

        async let transcriptTask = transcribe(url: sourceURL)
        async let silenceTask = detectSilence(url: sourceURL)

        let transcriptEntries: [SubtitleEntry]
        do {
            transcriptEntries = try await transcriptTask
        } catch {
            throw Error.transcriptionFailed(error.localizedDescription)
        }

        onProgress(Progress(
            phase: .analyzingAudio,
            fractionComplete: 0.45,
            detail: Phase.analyzingAudio.localizedDetail
        ))

        // Write subtitles so cues become visible on the timeline and
        // `document.composedTranscriptCues` reflects them for the LLM
        // step. Done on MainActor because setSubtitles touches
        // @Published state.
        document.setSubtitles(transcriptEntries, forSegmentID: segmentID)

        // Audio silence is best-effort — if the scan fails (e.g. no
        // audio track), we proceed with an empty list rather than
        // aborting the whole first cut.
        let silentRanges: [ClosedRange<Double>]
        do {
            silentRanges = try await silenceTask
        } catch {
            silentRanges = []
        }

        // ============ Step 3: LLM edit decision ============
        onProgress(Progress(
            phase: .requestingAI,
            fractionComplete: 0.6,
            detail: Phase.requestingAI.localizedDetail
        ))

        let cues = document.composedTranscriptCues
        guard !cues.isEmpty else {
            onProgress(Progress(
                phase: .complete,
                fractionComplete: 1.0,
                detail: Phase.complete.localizedDetail
            ))
            return Summary(
                keptCueCount: 0,
                cutCueCount: 0,
                longSilenceCount: silentRanges.filter { $0.upperBound - $0.lowerBound >= 1.0 }.count
            )
        }

        let segments = cues.map { cue in
            TranscriptSegment(
                startSeconds: cue.composedStart,
                endSeconds: cue.composedEnd,
                text: cue.text
            )
        }

        let config = OpenAIConfiguration.fromEnvironment()
            ?? RelayClient.configurationFromDefaults()
        let client = OpenAIClient(configuration: config)
        let service = LLMEditorService(client: client)

        let decision: LLMEditorService.EditDecision
        do {
            decision = try await service.selectSegments(segments)
        } catch {
            throw Error.llmFailed(error.localizedDescription)
        }

        // ============ Step 4: apply cuts ============
        // macOS stops at .complete after producing the LLM snapshot
        // and lets the user accept cuts via the Copilot UI. iOS has
        // no intermediate review step so we apply keep/cut directly
        // and surface the summary to the caller — but we don't
        // invent a new user-visible phase label for this; the
        // .complete progress covers it.
        let keepSet = Set(decision.keepIndices)
        let toCutIDs: Set<UUID> = Set(
            cues.enumerated()
                .filter { !keepSet.contains($0.offset) }
                .map { $0.element.id }
        )

        let removed: Int
        if toCutIDs.isEmpty {
            removed = 0
        } else {
            removed = document.removeCues(ids: toCutIDs)
        }

        onProgress(Progress(
            phase: .complete,
            fractionComplete: 1.0,
            detail: Phase.complete.localizedDetail
        ))

        return Summary(
            keptCueCount: keepSet.count,
            cutCueCount: removed,
            longSilenceCount: silentRanges.filter { $0.upperBound - $0.lowerBound >= 1.0 }.count
        )
    }

    // MARK: - Individual phases (also callable standalone)

    /// Step 1 — speech recognition. Thin pass-through to IOSTranscriber
    /// kept here so the workflow surface lists all phases uniformly.
    static func transcribe(url: URL) async throws -> [SubtitleEntry] {
        try await IOSTranscriber.transcribe(fileURL: url)
    }

    /// Step 2 — audio silence detection via the shared
    /// `AudioQualityService`. Returns sorted, non-overlapping ranges.
    static func detectSilence(url: URL) async throws -> [ClosedRange<Double>] {
        let service = AudioQualityService()
        let result = try await service.analyze(url: url)
        return result.silentRanges
    }

    // MARK: - Helpers

    @MainActor
    private static func primaryTargetSegment(in document: ProjectDocument) -> TimelineSegment? {
        if let selected = document.selectedSegment { return selected }
        return document.tracks.first(where: { $0.kind == .video })?.segments.first
    }

    private static func resolveURL(for media: MediaAssetRecord, root: URL) -> URL {
        if let rel = media.derived.proxyRelativePath {
            let u = root.appending(path: rel)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return URL(fileURLWithPath: media.sourcePath)
    }
}
