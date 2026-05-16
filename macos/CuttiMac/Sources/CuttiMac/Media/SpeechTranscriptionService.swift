import AVFoundation
import Foundation
import NaturalLanguage
import Speech
import CuttiKit

/// Transcribes audio from a video file.
///
/// Local Qwen3-ASR + ForcedAligner is the primary engine for every
/// supported language (Chinese, Cantonese, English). Apple SFSpeech
/// is the system-provided fallback used when the Qwen sidecar isn't
/// installed (Intel/MAS hosts, or first-launch before the model has
/// been downloaded) or fails at runtime.
struct SpeechTranscriptionService: Sendable {
    struct Result: Sendable {
        /// Cleaned higher-level transcript segments for display/debugging.
        let displaySegments: [TranscriptSegment]
        /// Best available token/word-level timings for downstream silence trimming.
        let wordSegments: [TranscriptSegment]
    }

    enum TranscriptionError: Error, LocalizedError, Sendable {
        case recognizerUnavailable
        case authorizationDenied
        case noResult
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return L("Speech recognition isn't available for this language on this device.")
            case .authorizationDenied:
                return L("Cutti needs Speech Recognition permission. Enable it in System Settings → Privacy & Security → Speech Recognition.")
            case .noResult:
                return L("Transcription returned no text. The audio may be silent or too short.")
            case .recognitionFailed:
                return L("Transcription failed. Please try again.")
            }
        }
    }

    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    // MARK: - Public

    func transcribe(url: URL, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let profile = CuttiSettings.resolvedSpeechProfile(
            fallbackLocale: locale
        )
        var lastError: Error?
        var didFallBackFromQwen = false

        // [diag-2026-05-16] Tag every transcribe call with a short ID
        // so we can correlate progress emissions / backend-switch logs
        // with the originating call, and dump a Swift backtrace of who
        // called us. We're chasing a bug where the chat bubble flips
        // to "Transcribing with Apple Speech…" mid-flight while the
        // Qwen sidecar is still healthy — need to confirm whether a
        // second transcribe() call is firing or whether the bubble
        // text is mutated through some other code path.
        let callID = String(UUID().uuidString.prefix(8))
        let callerStack = Thread.callStackSymbols.dropFirst().prefix(8).joined(separator: "\n     ")
        print("🎙️ [SST.enter] callID=\(callID) url=\(url.lastPathComponent) chain=[\(profile.backendChain.map { String(describing: $0) }.joined(separator: ","))]")
        print("🎙️ [SST.enter] callID=\(callID) callerStack:\n     \(callerStack)")

        // Wrap onProgress so we see the exact strings emitted up to
        // the UI, in the same order they were produced.
        let underlyingOnProgress = onProgress
        let wrappedOnProgress: (@Sendable (String) -> Void)? = underlyingOnProgress == nil ? nil : { @Sendable msg in
            print("🎙️ [SST.progress] callID=\(callID) msg=\(msg)")
            underlyingOnProgress?(msg)
        }

        let chain = profile.backendChain
        for (index, backend) in chain.enumerated() {
            print("🎙️ [SST.try] callID=\(callID) step=\(index + 1)/\(chain.count) backend=\(backend)")
            do {
                let result = try await transcribe(
                    url: url,
                    with: backend,
                    profile: profile,
                    onProgress: wrappedOnProgress
                )
                print("🎙️ [SST.result] callID=\(callID) backend=\(backend) display=\(result.displaySegments.count) words=\(result.wordSegments.count)")
                if !result.displaySegments.isEmpty || !result.wordSegments.isEmpty {
                    if didFallBackFromQwen, backend == .appleSpeech {
                        // The user asked for the higher-quality local
                        // engine, didn't get it, and now sees Apple
                        // Speech output. Surface that explicitly so
                        // the perceived quality drop isn't silent.
                        onProgress?(L("Local speech model was unavailable — used Apple Speech for this clip."))
                    }
                    return result
                }
                lastError = TranscriptionError.noResult
                print("🎤 \(backend.title) returned no transcript")
            } catch {
                lastError = error
                print("🎤 \(backend.title) failed: \(error.localizedDescription)")
            }

            if backend == .qwenAsrSidecar {
                didFallBackFromQwen = true
            }

            if index + 1 < chain.count {
                print("🎤 Falling back to \(chain[index + 1].title)")
            }
        }

        throw lastError ?? TranscriptionError.noResult
    }

    private func transcribe(
        url: URL,
        with backend: SpeechRecognitionBackend,
        profile: SpeechRecognitionProfile,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> Result {
        switch backend {
        case .appleSpeech:
            // [diag-2026-05-16] If we EVER hit this branch, dump a
            // full backtrace. The user reported the chat bubble
            // flipping to "Transcribing with Apple Speech…" mid-flight
            // without Qwen actually failing — this stack will tell us
            // who called transcribe() with .appleSpeech (either a
            // direct call, or a fallthrough from the chain loop after
            // a Qwen .noResult / throw).
            let stack = Thread.callStackSymbols.prefix(25).joined(separator: "\n     ")
            print("🎙️ [SST.appleSpeech.DISPATCH] url=\(url.lastPathComponent) STACK:\n     \(stack)")
            onProgress?(L("Transcribing with Apple Speech…"))
            let segments = try await transcribeWithSFSpeech(url: url, locale: profile.locale)
            return Result(displaySegments: segments, wordSegments: segments)
        case .qwenAsrSidecar:
            onProgress?(L("Transcribing locally…"))
            return try await transcribeWithQwenAsrSidecar(
                url: url,
                profile: profile,
                onProgress: onProgress
            )
        }
    }

    // MARK: - Qwen3-ASR (local sidecar)

    /// Bridges the local PyTorch sidecar into the same `Result` shape
    /// the cue builder consumes for Apple Speech. The sidecar already
    /// returns per-character timestamps for CJK and per-word for
    /// Latin languages, so we map its `items` directly into
    /// `wordSegments` without going through `expandTimingText`
    /// (which is for backends that emit phrase-sized chunks).
    private func transcribeWithQwenAsrSidecar(
        url: URL,
        profile: SpeechRecognitionProfile,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> Result {
        // Map cutti's two-letter language code into the aligner's
        // English-named language vocabulary.
        let qwenLanguage: String?
        switch profile.languageCode {
        case "zh":
            qwenLanguage = "Chinese"
        case "yue":
            qwenLanguage = "Cantonese"
        case "en":
            qwenLanguage = "English"
        default:
            qwenLanguage = nil
        }

        // Pre-extract the audio track to a small 16 kHz mono WAV
        // before handing it to the sidecar. The sidecar's
        // `librosa.load` path uses libsndfile via PySoundFile when
        // the container is supported and falls back to a
        // single-threaded `audioread` decode pipeline otherwise.
        // For video containers (`.mov`, `.mp4`, `.mkv`) the fallback
        // hits, and on multi-GB sources it dominates runtime —
        // observed in the wild: a 51 GB / 24 min .mov proxy spent
        // ~10+ minutes inside librosa before the model ever ran.
        //
        // AVAssetReader decodes only the audio track, with
        // hardware-accelerated AAC / Apple Lossless / ALAC / etc.
        // decoders, into a ~46 MB WAV that PySoundFile reads natively.
        // For users on Intel / MAS hosts who don't have the sidecar,
        // this path is bypassed entirely (SpeechRecognitionService
        // routes to SFSpeech instead).
        let extractT0 = Date()
        let extractedURL: URL
        do {
            onProgress?(L("Extracting audio for transcription…"))
            extractedURL = try await AudioExtraction.extractMono16kWav(from: url)
            print("⏱️  [transcribe.extract] done in \(String(format: "%.2f", Date().timeIntervalSince(extractT0)))s → \(extractedURL.lastPathComponent)")
        } catch {
            print("⏱️  [transcribe.extract] FAILED: \(error.localizedDescription) — falling back to handing the source path to the sidecar (slow librosa fallback expected)")
            extractedURL = url
        }
        defer {
            if extractedURL != url {
                try? FileManager.default.removeItem(at: extractedURL)
            }
        }

        onProgress?(L("Loading speech model (first run takes ~10s)…"))
        let asrT0 = Date()

        // Spin up a poller that asks the sidecar what stage it's
        // in every couple of seconds while the (blocking) transcribe
        // HTTP call is in flight. Without this the chat panel sees
        // exactly one event ("Loading speech model…") for the
        // entire 5–15 minute inference on a long file — the user
        // can't tell whether the app is alive, let alone which
        // chunk is being processed.
        let progressTask = Task { @Sendable in
            // Initial small delay so quick (≤2s) transcribes don't
            // flicker an extra status line into the chat.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while !Task.isCancelled {
                if let snap = await QwenAsrSidecarClient.shared.fetchProgress() {
                    let elapsed = Date().timeIntervalSince(asrT0)
                    let elapsedStr = Self.formatTranscribeElapsed(elapsed)
                    let stageLabel = Self.humanizeAsrStage(snap.stage)
                    let line: String
                    if snap.chunkTotal > 0 {
                        // After ASR finishes its 8/8 chunks the forced
                        // aligner kicks in with its OWN chunk loop
                        // (often "0/1" → "1/1"). Without a stage-aware
                        // prefix the UI looks like "片段 8/8" → "片段
                        // 0/1" which reads as the progress regressing.
                        // Use the human-readable stage label as the
                        // prefix when one exists; fall back to the
                        // generic "chunk" word for the ASR phase
                        // (whose humanize maps to empty string by
                        // design).
                        let prefix = stageLabel.isEmpty ? L("chunk") : stageLabel
                        line = String(format: L("%@ %d/%d (%@ elapsed)"),
                                      prefix, snap.chunkIndex, snap.chunkTotal, elapsedStr)
                    } else if stageLabel.isEmpty {
                        line = "(\(elapsedStr) " + L("elapsed") + ")"
                    } else {
                        line = "\(stageLabel) (\(elapsedStr) " + L("elapsed") + ")"
                    }
                    onProgress?(line)
                    print("⏱️  [transcribe.asr.progress] \(line)")
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        defer { progressTask.cancel() }

        let response = try await QwenAsrSidecarClient.shared.transcribe(
            audioPath: extractedURL.path,
            language: qwenLanguage,
            context: nil
        )
        progressTask.cancel()
        print("⏱️  [transcribe.asr] sidecar call done in \(String(format: "%.2f", Date().timeIntervalSince(asrT0)))s")

        print("🎤 Qwen3-ASR: display=\(response.displaySegments.count) timing=\(response.wordSegments.count) rtf=\(response.realTimeFactor.map { String(format: "%.3f", $0) } ?? "?")")
        if let first = response.wordSegments.first {
            print("🎤   first: t=\(String(format: "%.2f", first.startSeconds))s end=\(String(format: "%.2f", first.endSeconds))s \"\(first.text)\"")
        }
        if let last = response.wordSegments.last {
            print("🎤   last:  t=\(String(format: "%.2f", last.startSeconds))s end=\(String(format: "%.2f", last.endSeconds))s \"\(last.text)\"")
        }

        return Result(
            displaySegments: response.displaySegments,
            wordSegments: response.wordSegments
        )
    }

    // MARK: - SFSpeech (fallback)

    private func transcribeWithSFSpeech(url: URL, locale: Locale) async throws -> [TranscriptSegment] {
        try await requestAuthorization()

        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if #available(macOS 15, *) {
            request.requiresOnDeviceRecognition = false
        }

        let rawSegments: [(timestamp: Double, duration: Double, substring: String)] =
            try await withCheckedThrowingContinuation { continuation in
                nonisolated(unsafe) var hasResumed = false
                recognizer.recognitionTask(with: request) { result, error in
                    guard !hasResumed else { return }
                    if let error {
                        hasResumed = true
                        continuation.resume(throwing: TranscriptionError.recognitionFailed(error.localizedDescription))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    hasResumed = true
                    let segments = result.bestTranscription.segments.map {
                        (timestamp: $0.timestamp, duration: $0.duration, substring: $0.substring)
                    }
                    print("🎤 SFSpeech returned \(segments.count) raw word-segments")
                    continuation.resume(returning: segments)
                }
            }

        // SFSpeech for Chinese frequently returns PHRASE-sized
        // segments — a single `SFTranscriptionSegment.substring` like
        // "我今天去学校" carrying one (timestamp, duration) covering
        // every character. If we shipped these straight to the cue
        // builder, `chunkWords` would treat the whole phrase as a
        // single "word" and emit one cue whose full text is shown the
        // moment the FIRST character is spoken — so the user sees
        // "学校" on screen seconds before they hear it, exactly the
        // "subtitles run faster than reality" symptom users have
        // reported. Apply per-token expansion to each multi-character
        // substring via equal-time interpolation. CJK falls back to per-character
        // splitting inside `tokenizeTimingText`. Latin substrings
        // already arrive token-sized; the expansion is a no-op for
        // single tokens.
        let langCode = locale.language.languageCode?.identifier ?? "en"
        var expanded: [TranscriptSegment] = []
        expanded.reserveCapacity(rawSegments.count)
        for seg in rawSegments {
            let end = seg.timestamp + seg.duration
            guard end > seg.timestamp + 0.01 else { continue }
            expanded.append(contentsOf: Self.expandTimingText(
                seg.substring,
                start: seg.timestamp,
                end: end,
                languageCode: langCode
            ))
        }
        print("🎤 SFSpeech: expanded \(rawSegments.count) raw segments into \(expanded.count) timing tokens (lang=\(langCode))")

        // SFSpeech for Chinese systematically under-reports per-word
        // `duration`: the reported end often lands mid-way through the
        // final syllable's phoneme, so a cut at that boundary lops off
        // the last character's audio. Pad each token's end, clamped by
        // the next token's start (minus a tiny epsilon so the two
        // don't meet exactly) to avoid bleeding. After the per-char
        // expansion above, intra-phrase tokens are butted up
        // back-to-back, so the clamp keeps their pad at zero — only
        // phrase-final tokens before a real silence gap consume the
        // full pad, which is exactly where the Chinese tail
        // truncation is worst. 500ms preserves most of the Chinese
        // declarative tail without leaving long trailing dead air in
        // the final cut.
        let tailPad: Double = 0.5
        let tailEpsilon: Double = 0.02
        var addedPadTotalMs: Double = 0
        var maxPadMs: Double = 0
        let padded: [TranscriptSegment] = expanded.enumerated().map { index, seg in
            let rawEnd = seg.endSeconds
            let ceiling: Double
            if index + 1 < expanded.count {
                ceiling = max(rawEnd, expanded[index + 1].startSeconds - tailEpsilon)
            } else {
                ceiling = .infinity
            }
            let paddedEnd = min(rawEnd + tailPad, ceiling)
            let padMs = (paddedEnd - rawEnd) * 1000
            addedPadTotalMs += padMs
            maxPadMs = max(maxPadMs, padMs)
            return TranscriptSegment(
                startSeconds: seg.startSeconds,
                endSeconds: paddedEnd,
                text: seg.text
            )
        }
        let avgPadMs = expanded.isEmpty ? 0 : addedPadTotalMs / Double(expanded.count)
        print(String(
            format: "🎤 Chinese tail-pad applied: target=%.0fms, avg added=%.0fms, max added=%.0fms across %d tokens",
            tailPad * 1000, avgPadMs, maxPadMs, expanded.count
        ))
        return padded
    }

    private func requestAuthorization() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            throw TranscriptionError.authorizationDenied
        }
    }

    static func cleanTranscriptText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        var cleaned = text.replacingOccurrences(
            of: #"<\|[^|]+?\|>"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([，。！？；：,.!?;:])"#,
            with: "$1",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func expandTimingText(
        _ text: String,
        start: Double,
        end: Double,
        languageCode: String
    ) -> [TranscriptSegment] {
        let cleaned = cleanTranscriptText(text)
        guard !cleaned.isEmpty, end - start > 0.01 else { return [] }

        let tokens = tokenizeTimingText(cleaned, languageCode: languageCode)
        guard tokens.count > 1 else {
            guard !isPunctuationOnly(cleaned) else { return [] }
            return [TranscriptSegment(startSeconds: start, endSeconds: end, text: cleaned)]
        }

        let weights = tokens.map(tokenTimingWeight)
        let totalWeight = max(1, weights.reduce(0, +))
        let totalDuration = end - start
        var cursor = start

        return tokens.enumerated().compactMap { index, token in
            let nextEnd: Double
            if index == tokens.count - 1 {
                nextEnd = end
            } else {
                let duration = totalDuration * Double(weights[index]) / Double(totalWeight)
                nextEnd = min(end, cursor + max(duration, 0.01))
            }

            defer { cursor = nextEnd }
            guard nextEnd > cursor + 0.001 else { return nil }
            return TranscriptSegment(
                startSeconds: cursor,
                endSeconds: nextEnd,
                text: token
            )
        }
    }

    static func tokenizeTimingText(_ cleanedText: String, languageCode: String) -> [String] {
        guard !cleanedText.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = cleanedText
        let fullRange = cleanedText.startIndex..<cleanedText.endIndex
        tokenizer.setLanguage(NLLanguage(rawValue: languageCode))

        var tokens: [String] = []
        tokenizer.enumerateTokens(in: fullRange) { range, _ in
            let token = cleanTranscriptText(String(cleanedText[range]))
            if !token.isEmpty, !isPunctuationOnly(token) {
                tokens.append(token)
            }
            return true
        }

        if tokens.count > 1 {
            return tokens
        }

        if containsCompactCJK(cleanedText), cleanedText.count > 1 {
            let chars = cleanedText.map(String.init).map(cleanTranscriptText).filter {
                !$0.isEmpty && !isPunctuationOnly($0)
            }
            if chars.count > 1 {
                return chars
            }
        }

        if cleanedText.contains(where: \.isWhitespace) {
            let split = cleanedText
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .map(cleanTranscriptText)
                .filter { !$0.isEmpty && !isPunctuationOnly($0) }
            if !split.isEmpty {
                return split
            }
        }

        return [cleanedText]
    }

    private static func groupTimingSegmentsForDisplay(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        var grouped: [TranscriptSegment] = []
        var current: [TranscriptSegment] = []
        let hardGapThreshold = 0.65
        let softGapThreshold = 0.25
        let maxDuration = 6.0
        let maxTokens = 18

        for (index, segment) in segments.enumerated() {
            current.append(segment)

            let nextGap: Double
            if index + 1 < segments.count {
                nextGap = segments[index + 1].startSeconds - segment.endSeconds
            } else {
                nextGap = .infinity
            }

            let currentDuration = segment.endSeconds - current.first!.startSeconds
            let hardBoundary = nextGap > hardGapThreshold || endsSentence(segment.text)
            let softBoundary = nextGap > softGapThreshold || endsClause(segment.text)
            let tooLong = currentDuration >= maxDuration || current.count >= maxTokens
            let shouldFlush = hardBoundary || (tooLong && softBoundary) || index == segments.count - 1

            if shouldFlush {
                grouped.append(TranscriptSegment(
                    startSeconds: current.first!.startSeconds,
                    endSeconds: current.last!.endSeconds,
                    text: joinDisplayText(current.map(\.text))
                ))
                current = []
            }
        }

        return grouped
    }

    private static func joinDisplayText(_ parts: [String]) -> String {
        let cleaned = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var result = cleaned.first else { return "" }

        for token in cleaned.dropFirst() {
            if shouldJoinWithoutSpace(previous: result.last, next: token.first) {
                result += token
            } else {
                result += " " + token
            }
        }

        return result
    }

    private static func tokenTimingWeight(_ token: String) -> Int {
        let count = token.unicodeScalars.reduce(0) { partialResult, scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return partialResult }
            if CharacterSet.punctuationCharacters.contains(scalar) { return partialResult }
            return partialResult + 1
        }
        return max(count, 1)
    }

    private static func containsCompactCJK(_ text: String) -> Bool {
        text.count > 1 && text.unicodeScalars.contains(where: isCJKScalar)
    }

    private static func isPunctuationOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？.!?".contains(last)
    }

    private static func endsClause(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "，、；：,;:".contains(last)
    }

    private static func shouldJoinWithoutSpace(previous: Character?, next: Character?) -> Bool {
        guard let previous, let next else { return false }
        if isCJKScalarSet(previous) && isCJKScalarSet(next) { return true }
        if isCJKScalarSet(previous) && isPunctuationCharacter(next) { return true }
        if isPunctuationCharacter(previous) && isCJKScalarSet(next) { return true }
        return false
    }

    private static func isCJKScalarSet(_ char: Character) -> Bool {
        char.unicodeScalars.contains(where: isCJKScalar)
    }

    private static func isPunctuationCharacter(_ char: Character) -> Bool {
        char.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    /// Render an elapsed-time interval as a compact `"42s"` / `"2m 14s"`
    /// string for the chat panel's per-chunk progress line.
    fileprivate static func formatTranscribeElapsed(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    /// Map the sidecar's internal stage tag (e.g. `"asr.inference"`,
    /// `"align.inference"`, `"load_audio"`) into a user-friendly
    /// label that fits the existing analysis-chat tone. We
    /// deliberately avoid leaking model/process names like
    /// "Qwen3-ASR" or "sidecar" — end users don't care which model
    /// or subprocess is doing the work, only what step the app is
    /// on. The asr.inference stage returns an empty label because
    /// its chunk count (e.g. "chunk 7/41") already conveys progress
    /// without needing a redundant prefix.
    fileprivate static func humanizeAsrStage(_ stage: String) -> String {
        switch stage {
        case "idle":            return L("Preparing transcription…")
        case "load_audio":      return L("Loading audio")
        case "asr.inference":   return ""
        case "align.inference": return L("Aligning timestamps")
        case "serializing":     return L("Finalising transcript")
        case "failed":          return L("Transcription error")
        default:                return L("Transcribing") + " (\(stage))"
        }
    }
}
