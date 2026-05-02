import Foundation
import CuttiKit

/// Headless iOS runner for LLM-backed preset tiles — the user wanted
/// shortcut buttons instead of a chat box, so every preset gets
/// executed in a single `chatCompletion` round-trip with a fixed
/// system prompt.
///
/// Presets either:
///   1. Return plain text that's shown in a scrollable sheet
///      (`.text(body)`), or
///   2. Mutate the project directly and return a summary toast
///      (`.applied(toast)`) — e.g. chapter generation writes the
///      suggested markers onto `document.chapters`.
///
/// Presets that fundamentally need a tool-call agent loop (speaker
/// diarization, vision empty-frame detection, full smart-cut) still
/// stay `.cloudPending` with a "coming soon" toast.
enum IOSAIPresetRunner {
    enum Outcome {
        case text(String)
        case applied(toast: String)
    }

    enum Error: Swift.Error, LocalizedError {
        case notSignedIn
        case noTranscript
        case emptyReply
        case parseFailed(String)
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:   return "请先登录 Cutti 账号以调用云端 AI。"
            case .noTranscript:  return "请先运行「智能字幕」，让我知道视频讲了什么。"
            case .emptyReply:    return "云端没有返回结果，请稍后再试。"
            case .parseFailed(let m): return "解析 AI 回复失败：\(m)"
            case .underlying(let m): return m
            }
        }
    }

    /// All preset IDs that have an iOS implementation today.
    ///
    /// Note: `smart.full` is intentionally NOT here — that preset
    /// runs through `SmartCutWorkflow` instead, which emits per-phase
    /// progress (transcribe → audio → LLM → apply) the way macOS's
    /// `FullAnalysisPipeline` does. Listing it here would route it
    /// through the generic one-shot runner below and lose the step
    /// progress UX.
    static let supportedIDs: Set<String> = [
        "gen.summary",
        "gen.title",
        "gen.chapters",
        "gen.broll",
        "gen.overlayTitles",
        "speaker.detect",
        "speaker.list",
        "speaker.mute",
        "vision.empty",
        "vision.black",
    ]

    /// Presets that require only local analysis (no cloud call, no
    /// transcript). Lets us skip the `notSignedIn` / `noTranscript`
    /// gates that the cloud presets need.
    static let localOnlyIDs: Set<String> = [
        "vision.empty",
        "vision.black",
    ]

    /// Optional free-form user input captured before the runner is
    /// invoked. Today only `speaker.list` / `speaker.mute` use it —
    /// the UI pops a TextField so the user can say "speaker 2" /
    /// "王老师" etc. Empty string is accepted (the LLM will pick the
    /// most prominent speaker).
    struct UserInput {
        let speakerTag: String
    }

    @MainActor
    static func run(
        presetID: String,
        document: ProjectDocument,
        userInput: UserInput = UserInput(speakerTag: "")
    ) async throws -> Outcome {
        // Local-only presets short-circuit auth/transcript checks.
        if localOnlyIDs.contains(presetID) {
            return try await runLocalVisionPreset(presetID: presetID, document: document)
        }

        // Every cloud call needs authed relay creds; we surface a
        // friendly error rather than letting the relay 401.
        let token = RelaySession.currentBearerToken() ?? ""
        guard !token.isEmpty else { throw Error.notSignedIn }

        let cues = document.composedTranscriptCues
        guard !cues.isEmpty else { throw Error.noTranscript }
        let transcript = cues
            .map { String(format: "[%.1fs] %@", $0.composedStart, $0.text) }
            .joined(separator: "\n")

        let config = OpenAIConfiguration.fromEnvironment()
            ?? RelayClient.configurationFromDefaults()
        let client = OpenAIClient(configuration: config)

        switch presetID {
        case "gen.summary":
            return .text(try await plainText(
                client: client,
                system: "You are a concise video-summary assistant. Reply in the same primary language as the transcript.",
                user: """
                Here is the transcript of the current video timeline, with \
                rough timestamps. Write a 3-4 sentence summary that captures \
                the key points a viewer would take away. Do NOT add a \
                preamble, bullet points, or headings — return the summary \
                paragraph only.

                Transcript:
                \(transcript)
                """
            ))

        case "gen.title":
            return .text(try await plainText(
                client: client,
                system: "You are a catchy short-form video title generator. Reply in the same primary language as the transcript.",
                user: """
                Based on this transcript, propose 3 short video titles \
                (under 25 characters each). Each title should be punchy and \
                hook-driven. Return them as a numbered list — no commentary.

                Transcript:
                \(transcript)
                """
            ))

        case "gen.broll":
            return .text(try await plainText(
                client: client,
                system: "You are a B-roll editor. Reply in the same primary language as the transcript.",
                user: """
                Identify 3-6 moments in this transcript where a B-roll clip \
                (chart, animation, image, or screen recording) would help \
                the viewer. For each, output one line formatted exactly as:
                `MM:SS  <kind>  <one-sentence idea>`

                Kinds must be one of: chart, animation, image, screen, map, \
                dataTable, other.

                Transcript:
                \(transcript)
                """
            ))

        case "gen.overlayTitles":
            return .text(try await plainText(
                client: client,
                system: "You are a motion-graphics writer. Reply in the same primary language as the transcript.",
                user: """
                Propose 3-5 on-screen title cards to emphasize the key \
                moments in this transcript. Format each line exactly as:
                `MM:SS  <title text (max 20 chars)>  <optional kicker (max 30 chars)>`

                No commentary, just the lines.

                Transcript:
                \(transcript)
                """
            ))

        case "gen.chapters":
            return try await runChapterGeneration(
                client: client,
                transcript: transcript,
                document: document
            )

        case "speaker.detect":
            return .text(try await plainText(
                client: client,
                system: "You are a diarization assistant. Reply in the same primary language as the transcript.",
                user: """
                Below is a timestamped transcript of a video. Identify \
                the distinct speakers and label who says what. Return a \
                clean reading-order list formatted as:

                Speaker A:
                  [MM:SS] …
                  [MM:SS] …

                Speaker B:
                  [MM:SS] …

                If you're not sure there are multiple speakers, say \
                "Only one speaker detected." Do not add preamble.

                Transcript:
                \(transcript)
                """
            ))

        case "speaker.list":
            let whichSpeaker = userInput.speakerTag.isEmpty
                ? "the most prominent speaker"
                : userInput.speakerTag
            return .text(try await plainText(
                client: client,
                system: "You are a diarization assistant. Reply in the same primary language as the transcript.",
                user: """
                Below is a timestamped transcript. First identify each \
                speaker. Then list every line spoken by \(whichSpeaker). \
                Format each line as `[MM:SS] <text>`. Return only the \
                list, no preamble.

                Transcript:
                \(transcript)
                """
            ))

        case "speaker.mute":
            let whichSpeaker = userInput.speakerTag.isEmpty
                ? "the most prominent speaker"
                : userInput.speakerTag
            return .text(try await plainText(
                client: client,
                system: "You are a diarization assistant. Reply in the same primary language as the transcript.",
                user: """
                Below is a timestamped transcript. Identify each \
                speaker, then list the timespans where \(whichSpeaker) \
                is talking — these are the segments the user will mute. \
                Format each line as `[MM:SS – MM:SS] <first few words>` \
                and end with a single summary line like "共 N 段，合计约 X 秒。"

                Transcript:
                \(transcript)
                """
            ))

        default:
            throw Error.underlying("未知的云端预设：\(presetID)")
        }
    }

    // MARK: - Private

    private static func plainText(
        client: OpenAIClient,
        system: String,
        user: String
    ) async throws -> String {
        let response = try await client.chatCompletion(
            messages: [.system(system), .user(user)],
            temperature: 0.6
        )
        let text = (response.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Error.emptyReply }
        return text
    }

    /// Ask the model for a JSON array of `{start, title}` chapter
    /// markers clamped to [0, duration], then overwrite
    /// `document.chapters` with the parsed result. Toast reports the
    /// count so the user knows the timeline changed.
    @MainActor
    private static func runChapterGeneration(
        client: OpenAIClient,
        transcript: String,
        document: ProjectDocument
    ) async throws -> Outcome {
        let duration = document.primaryDurationSeconds
        guard duration > 1 else {
            throw Error.underlying("时间线太短，无法生成章节。")
        }

        let user = """
        Partition the timeline into 4-8 chapters based on natural topic \
        boundaries in the transcript below. Each chapter needs a short \
        label (max 20 chars) in the same primary language as the \
        transcript.

        The timeline runs from 0 to \(String(format: "%.2f", duration)) seconds.

        Reply with ONLY a JSON array — no markdown fence, no prose — \
        shaped exactly like:
        [{"start": 0.0, "title": "Intro"}, {"start": 12.4, "title": "…"}]

        Rules:
          - First entry MUST have start == 0.
          - `start` values must be strictly increasing and inside \
            [0, \(String(format: "%.2f", duration))].
          - Minimum 4, maximum 8 entries.

        Transcript:
        \(transcript)
        """

        let response = try await client.chatCompletion(
            messages: [
                .system("You are a video chapter planner. Reply with JSON only."),
                .user(user),
            ],
            temperature: 0.4
        )
        let raw = (response.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw Error.emptyReply }

        let chapters = try parseChapters(from: raw, duration: duration)
        guard !chapters.isEmpty else {
            throw Error.parseFailed("未能解析出任何章节")
        }

        document.replaceChapters(with: chapters)
        return .applied(toast: "已生成 \(chapters.count) 个章节")
    }

    /// Tolerant JSON parser — strips markdown fences / stray prose
    /// around the array if the model adds any, then converts the raw
    /// `{start,title}` pairs into non-overlapping `VideoChapter`s by
    /// chaining each start into the next one's `endSeconds`.
    static func parseChapters(from raw: String, duration: Double) throws -> [VideoChapter] {
        // Extract the first `[ … ]` block — models sometimes wrap the
        // JSON in ```json fences or prefix it with a sentence.
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), end > start else {
            throw Error.parseFailed("未找到 JSON 数组")
        }
        let jsonSlice = String(raw[start...end])
        guard let data = jsonSlice.data(using: .utf8) else {
            throw Error.parseFailed("编码失败")
        }
        struct Entry: Decodable {
            let start: Double
            let title: String
        }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            throw Error.parseFailed(error.localizedDescription)
        }

        var cleaned: [Entry] = []
        for e in entries {
            let s = max(0, min(duration - 0.1, e.start))
            if let last = cleaned.last, s <= last.start + 0.2 { continue }
            let t = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            cleaned.append(Entry(start: s, title: String(t.prefix(40))))
        }
        guard !cleaned.isEmpty else { return [] }
        // Ensure first chapter anchors at 0.
        if cleaned[0].start > 0.2 {
            cleaned.insert(Entry(start: 0, title: "Intro"), at: 0)
        } else {
            cleaned[0] = Entry(start: 0, title: cleaned[0].title)
        }

        var out: [VideoChapter] = []
        for i in cleaned.indices {
            let s = cleaned[i].start
            let e = (i + 1 < cleaned.count) ? cleaned[i + 1].start : duration
            guard e > s + 0.2 else { continue }
            out.append(VideoChapter(startSeconds: s, endSeconds: e, title: cleaned[i].title))
        }
        return out
    }

    // MARK: - Smart cut (智能首剪)

    // MARK: - Vision (local, no cloud)

    /// Samples the primary video with Vision + CoreImage and returns
    /// the list of spans matching the preset. Result is surfaced as
    /// `.text(...)` so the user can eyeball the list before deciding
    /// whether to cut — Mac's chat-based equivalent lets the agent
    /// propose cuts too; we keep iOS conservative for v1.
    @MainActor
    private static func runLocalVisionPreset(
        presetID: String,
        document: ProjectDocument
    ) async throws -> Outcome {
        // Use the primary track's first segment as the analysis source.
        // If the user has multi-clip edits we still only scan the first
        // — matching Mac's "run on current selection" intent.
        guard let primary = document.tracks.first(where: { $0.kind == .video }),
              let firstSeg = primary.segments.first,
              let record = document.manifest.media.first(where: { $0.id == firstSeg.sourceVideoID })
        else {
            throw Error.underlying("请先添加视频片段")
        }

        let root = document.store.projectRoot
        let url: URL = {
            if let proxy = record.derived.proxyRelativePath {
                return root.appendingPathComponent(proxy)
            }
            return URL(fileURLWithPath: record.sourcePath)
        }()

        let spans: [IOSVisionAnalyzer.Span]
        switch presetID {
        case "vision.empty":
            spans = try await IOSVisionAnalyzer.findEmptyFaceSpans(url: url)
        case "vision.black":
            spans = try await IOSVisionAnalyzer.findBlackSpans(url: url)
        default:
            throw Error.underlying("未知的本地预设：\(presetID)")
        }

        if spans.isEmpty {
            return .text(presetID == "vision.empty"
                ? "画面里全程都有人出现，没有检测到空镜。"
                : "视频亮度正常，没有检测到黑场。")
        }

        let title = presetID == "vision.empty" ? "空镜（无人脸）" : "黑场 / 遮挡"
        var lines: [String] = ["\(title) · 共 \(spans.count) 段\n"]
        for span in spans {
            lines.append(String(
                format: "%@ – %@  (%.1fs)",
                formatMMSS(span.startSeconds),
                formatMMSS(span.endSeconds),
                span.durationSeconds
            ))
        }
        return .text(lines.joined(separator: "\n"))
    }

    private static func formatMMSS(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
