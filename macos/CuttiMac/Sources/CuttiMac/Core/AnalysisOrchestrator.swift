import Foundation
import CuttiKit

/// Orchestrates local media analysis by running transcription, scene analysis,
/// and audio quality detection in parallel, then merging results.
///
/// This is a pure coordinator — it owns no state and delegates to the
/// individual analysis services.
struct AnalysisOrchestrator: Sendable {
    let transcriptionService: SpeechTranscriptionService
    let sceneAnalysisService: SceneAnalysisService
    let audioQualityService: AudioQualityService

    init(
        transcriptionService: SpeechTranscriptionService = SpeechTranscriptionService(),
        sceneAnalysisService: SceneAnalysisService = SceneAnalysisService(),
        audioQualityService: AudioQualityService = AudioQualityService()
    ) {
        self.transcriptionService = transcriptionService
        self.sceneAnalysisService = sceneAnalysisService
        self.audioQualityService = audioQualityService
    }

    /// Run all local analysis services and produce a merged result.
    ///
    /// Transcription, scene analysis, and audio quality detection run
    /// concurrently via a task group.
    func analyze(
        sourceURL: URL,
        analysis: AnalysisSummary,
        onProgress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async throws -> LocalAnalysisResult {
        let overallT0 = Date()
        let durSec = analysis.durationSeconds
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? -1
        print("⏱️  analyze() start  file=\(sourceURL.lastPathComponent) duration=\(String(format: "%.1f", durSec))s size=\(fileSize) bytes")
        // [diag-2026-05-16] Dump caller stack so we can tell which UI
        // path triggered the analyze (one-click first cut vs
        // transcribeForDiarization vs analyzeAllRecords vs an LLM tool
        // call). We're chasing a bug where Apple Speech text appears
        // mid-flight — need to confirm whether a second analyze() was
        // kicked off without the timeline appearing to change.
        let callerStack = Thread.callStackSymbols.dropFirst().prefix(12).joined(separator: "\n     ")
        print("⏱️  analyze() callerStack:\n     \(callerStack)")

        // Run all three analyses concurrently. Each task is wrapped in
        // its own wall-clock measurement so the log shows where time
        // actually goes — typically the longest of these three wins
        // because they're racing. We also emit per-task kickoff +
        // completion events to `onProgress` so the chat panel can
        // render a streaming log-style trail (audio kicked off → audio
        // done in 10.6s, etc.) instead of a single static status line.
        async let transcriptTask: SpeechTranscriptionService.Result = {
            let t0 = Date()
            print("⏱️  [transcribe] kickoff")
            onProgress(AnalysisProgress(
                phase: .transcribing,
                fractionComplete: 0.1,
                detail: "Started"
            ))
            do {
                let result = try await transcriptionService.transcribe(url: sourceURL) { detail in
                    onProgress(AnalysisProgress(
                        phase: .transcribing,
                        fractionComplete: 0.15,
                        detail: detail
                    ))
                }
                let elapsed = Date().timeIntervalSince(t0)
                print("⏱️  [transcribe] done in \(String(format: "%.2f", elapsed))s")
                onProgress(AnalysisProgress(
                    phase: .transcribing,
                    fractionComplete: 0.6,
                    detail: "Done in \(Self.formatElapsed(elapsed))",
                    isPhaseComplete: true
                ))
                return result
            } catch {
                let elapsed = Date().timeIntervalSince(t0)
                print("⏱️  [transcribe] FAILED after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
                onProgress(AnalysisProgress(
                    phase: .transcribing,
                    fractionComplete: 0.6,
                    detail: "Failed after \(Self.formatElapsed(elapsed)) — \(error.localizedDescription)",
                    isPhaseComplete: true
                ))
                throw error
            }
        }()
        async let sceneTask: SceneAnalysisService.Result = {
            let t0 = Date()
            print("⏱️  [scene] kickoff")
            onProgress(AnalysisProgress(
                phase: .analyzingScenes,
                fractionComplete: 0.2,
                detail: "Started"
            ))
            do {
                let result = try await sceneAnalysisService.analyze(
                    url: sourceURL,
                    durationSeconds: analysis.durationSeconds
                )
                let elapsed = Date().timeIntervalSince(t0)
                print("⏱️  [scene] done in \(String(format: "%.2f", elapsed))s")
                onProgress(AnalysisProgress(
                    phase: .analyzingScenes,
                    fractionComplete: 0.5,
                    detail: "Done in \(Self.formatElapsed(elapsed))",
                    isPhaseComplete: true
                ))
                return result
            } catch {
                let elapsed = Date().timeIntervalSince(t0)
                print("⏱️  [scene] FAILED after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
                onProgress(AnalysisProgress(
                    phase: .analyzingScenes,
                    fractionComplete: 0.5,
                    detail: "Failed after \(Self.formatElapsed(elapsed))",
                    isPhaseComplete: true
                ))
                throw error
            }
        }()
        async let audioTask: AudioQualityService.Result = {
            let t0 = Date()
            print("⏱️  [audio] kickoff")
            onProgress(AnalysisProgress(
                phase: .analyzingAudio,
                fractionComplete: 0.2,
                detail: "Started"
            ))
            do {
                let result = try await audioQualityService.analyze(url: sourceURL)
                let elapsed = Date().timeIntervalSince(t0)
                print("⏱️  [audio] done in \(String(format: "%.2f", elapsed))s")
                onProgress(AnalysisProgress(
                    phase: .analyzingAudio,
                    fractionComplete: 0.5,
                    detail: "Done in \(Self.formatElapsed(elapsed))",
                    isPhaseComplete: true
                ))
                return result
            } catch {
                let elapsed = Date().timeIntervalSince(t0)
                print("⏱️  [audio] FAILED after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
                onProgress(AnalysisProgress(
                    phase: .analyzingAudio,
                    fractionComplete: 0.5,
                    detail: "Failed after \(Self.formatElapsed(elapsed))",
                    isPhaseComplete: true
                ))
                throw error
            }
        }()

        let transcription: SpeechTranscriptionService.Result
        let sceneResult: SceneAnalysisService.Result
        let audioResult: AudioQualityService.Result

        do {
            transcription = try await transcriptTask
        } catch {
            // Transcription failure is non-fatal; proceed with empty transcript
            transcription = SpeechTranscriptionService.Result(
                displaySegments: [],
                wordSegments: []
            )
        }

        do {
            sceneResult = try await sceneTask
        } catch {
            // Scene analysis failure is non-fatal; use empty defaults
            sceneResult = SceneAnalysisService.Result(
                semanticTags: [],
                sceneBoundaries: [],
                hasTalkingHead: false,
                facePresenceRatio: 0
            )
        }

        do {
            audioResult = try await audioTask
        } catch {
            audioResult = AudioQualityService.Result(
                issues: [],
                averageLoudnessDB: 0,
                silentRanges: [],
                peakLoudnessDB: 0,
                windowRMSValues: [],
                windowSeconds: 0.5
            )
        }

        // Note: we don't emit an extra `.analyzingAudio` "Merging…"
        // event here because the three task-level "done" events
        // already form the complete log-style trail in the chat
        // panel. The merge step itself is sub-millisecond.

        // Merge talking-head tag if applicable
        var tags = sceneResult.semanticTags
        if sceneResult.hasTalkingHead && !tags.contains("Talking Head") {
            tags.insert("Talking Head", at: 0)
        }

        // Re-segment transcript into sentences.
        // If token end times look precise enough, detect pauses from token gaps.
        // Otherwise rely more heavily on audio silence ranges.
        let timingTranscript = transcription.wordSegments.isEmpty
            ? transcription.displaySegments
            : transcription.wordSegments

        let refinedTranscript = Self.resegmentWithSilence(
            words: timingTranscript,
            silentRanges: audioResult.silentRanges
        )

        let energyCurve: AudioEnergyCurve? = audioResult.windowRMSValues.isEmpty
            ? nil
            : AudioEnergyCurve(
                values: audioResult.windowRMSValues,
                windowSeconds: audioResult.windowSeconds
            )

        let total = Date().timeIntervalSince(overallT0)
        let rtf = durSec > 0 ? total / durSec : 0
        print("⏱️  analyze() done in \(String(format: "%.2f", total))s (RTF=\(String(format: "%.2f", rtf))×) — \(refinedTranscript.count) sentences, \(sceneResult.sceneBoundaries.count) scene boundaries, \(audioResult.silentRanges.count) silent ranges")

        return LocalAnalysisResult(
            transcript: refinedTranscript,
            rawWordTranscript: timingTranscript,
            semanticTags: tags,
            sceneBoundaries: sceneResult.sceneBoundaries,
            hasTalkingHead: sceneResult.hasTalkingHead,
            audioIssues: audioResult.issues,
            silentRanges: audioResult.silentRanges,
            audioEnergyCurve: energyCurve
        )
    }

    /// Re-segment timed tokens into sentences using either token gaps or audio silence.
    private static func resegmentWithSilence(
        words: [TranscriptSegment],
        silentRanges: [ClosedRange<Double>]
    ) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }

        // Detect whether token end times look accurate by checking that token
        // durations are reasonable (< 3s for single tokens).
        let hasAccurateEndTimes = words.prefix(20).allSatisfy {
            $0.durationSeconds < 3.0 && $0.durationSeconds > 0.005
        }

        if hasAccurateEndTimes {
            return resegmentUsingWordGaps(words)
        }

        // Coarser timing path: use silence ranges + timestamp gap heuristics.
        if silentRanges.isEmpty {
            return chunkByWordCount(words, maxWords: 25)
        }
        return resegmentUsingSilenceRanges(words, silentRanges: silentRanges)
    }

    /// Segment using accurate token end times.
    /// Splits when the gap between one token's end and the next token's start
    /// exceeds a threshold.
    private static func resegmentUsingWordGaps(
        _ words: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let hardGapThreshold: Double = 0.45
        let softGapThreshold: Double = 0.2
        let maxSegmentDuration: Double = 5.0
        let maxWordsPerSegment = 16

        var segments: [TranscriptSegment] = []
        var currentWords: [TranscriptSegment] = []

        for (i, word) in words.enumerated() {
            currentWords.append(word)

            let nextGap: Double
            if i + 1 < words.count {
                nextGap = words[i + 1].startSeconds - word.endSeconds
            } else {
                nextGap = .infinity
            }

            let currentDuration = word.endSeconds - currentWords.first!.startSeconds
            let hardBoundary = nextGap > hardGapThreshold || endsSentence(word.text)
            let softBoundary = nextGap > softGapThreshold || endsClause(word.text)
            let tooLong = currentDuration >= maxSegmentDuration || currentWords.count >= maxWordsPerSegment
            // Force-flush when a segment grows past the hard duration/word cap
            // even without a natural boundary: this gives the LLM a chance to
            // cut mid-segment restart stutters like "不会吧还有人在不会吧还有人...".
            let forcedFlush = currentDuration >= maxSegmentDuration * 1.5
                || currentWords.count >= Int(Double(maxWordsPerSegment) * 1.5)
            let shouldFlush = hardBoundary || (tooLong && softBoundary) || forcedFlush || i == words.count - 1

            if shouldFlush && !currentWords.isEmpty {
                let text = joinTranscriptText(currentWords.map(\.text))
                // word.endSeconds was padded upstream in
                // SpeechTranscriptionService.paddedSegments; use it
                // as-is so the Chinese tail pad survives to the final
                // sentence boundary.
                let paddedEnd = word.endSeconds
                let rawGuess = word.startSeconds
                let nextStartDesc: String
                if i + 1 < words.count {
                    nextStartDesc = String(format: "%.3f", words[i + 1].startSeconds)
                } else {
                    nextStartDesc = "none"
                }
                print(String(
                    format: "🎤 tail-pad@sentence: '%@' end=%.3fs (wordStart=%.3fs, nextWordStart=%@, gap→next=%.3fs)",
                    text.suffix(12).description, paddedEnd, rawGuess, nextStartDesc, nextGap
                ))
                segments.append(TranscriptSegment(
                    startSeconds: currentWords.first!.startSeconds,
                    endSeconds: paddedEnd,
                    text: text
                ))
                currentWords = []
            }
        }

        if !currentWords.isEmpty {
            let text = joinTranscriptText(currentWords.map(\.text))
            segments.append(TranscriptSegment(
                startSeconds: currentWords.first!.startSeconds,
                endSeconds: currentWords.last!.endSeconds,
                text: text
            ))
        }

        print("🎤 Re-segmented by word gaps: \(words.count) words → \(segments.count) segments")
        return segments
    }

    /// Segment using silence ranges + timestamp heuristics.
    private static func resegmentUsingSilenceRanges(
        _ words: [TranscriptSegment],
        silentRanges: [ClosedRange<Double>]
    ) -> [TranscriptSegment] {
        let wordGapThreshold: Double = 1.5

        var segments: [TranscriptSegment] = []
        var currentWords: [TranscriptSegment] = []

        for (i, word) in words.enumerated() {
            currentWords.append(word)

            let wordEnd = word.startSeconds + min(word.durationSeconds, 0.5)
            let hasSilenceAfter = silentRanges.contains { range in
                range.lowerBound >= wordEnd - 0.1 && range.lowerBound <= wordEnd + 0.5
            }

            let hasLargeGap: Bool
            if i + 1 < words.count {
                let nextStart = words[i + 1].startSeconds
                let gap = nextStart - word.startSeconds - min(word.durationSeconds, 1.0)
                hasLargeGap = gap > wordGapThreshold
            } else {
                hasLargeGap = false
            }

            if (hasSilenceAfter || hasLargeGap) && !currentWords.isEmpty {
                let text = joinTranscriptText(currentWords.map(\.text))
                // Use the word's already-padded endSeconds directly.
                // SpeechTranscriptionService pads each word's end
                // (especially sentence-final words) to compensate for
                // SFSpeech under-reporting Chinese syllable tails, and
                // the pad is already clamped to next_word.start - 20ms,
                // so it's safe to use as-is. Earlier code here ran its
                // own `min(duration, distToNext * 0.5)` heuristic which
                // silently truncated the pad back to ~raw end, which is
                // why Chinese sentence tails kept getting clipped.
                let rawEnd = word.startSeconds + word.durationSeconds
                let segEnd = rawEnd
                #if DEBUG
                if hasLargeGap {
                    let nextStart = (i + 1 < words.count) ? words[i + 1].startSeconds : nil
                    let nextStartDesc = nextStart.map { String(format: "%.3f", $0) } ?? "none"
                    print(String(
                        format: "🎤 tail-pad: word '%@' end=%.3fs (rawStart=%.3fs + dur=%.3fs); next word start=%@",
                        word.text, segEnd, word.startSeconds, word.durationSeconds, nextStartDesc
                    ))
                }
                #endif
                segments.append(TranscriptSegment(
                    startSeconds: currentWords.first!.startSeconds,
                    endSeconds: segEnd,
                    text: text
                ))
                currentWords = []
            }
        }

        if !currentWords.isEmpty {
            let text = joinTranscriptText(currentWords.map(\.text))
            segments.append(TranscriptSegment(
                startSeconds: currentWords.first!.startSeconds,
                endSeconds: currentWords.last!.startSeconds + currentWords.last!.durationSeconds,
                text: text
            ))
        }

        print("🎤 Re-segmented (SFSpeech): \(words.count) words → \(segments.count) segments using \(silentRanges.count) silent ranges")
        return segments
    }

    /// Fallback: chunk words into groups when no silence data is available.
    private static func chunkByWordCount(_ words: [TranscriptSegment], maxWords: Int) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var i = 0
        while i < words.count {
            let end = min(i + maxWords, words.count)
            let chunk = Array(words[i..<end])
            let text = joinTranscriptText(chunk.map(\.text))
            segments.append(TranscriptSegment(
                startSeconds: chunk.first!.startSeconds,
                endSeconds: chunk.last!.startSeconds + chunk.last!.durationSeconds,
                text: text
            ))
            i = end
        }
        return segments
    }

    private static func joinTranscriptText(_ parts: [String]) -> String {
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

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldJoinWithoutSpace(previous: Character?, next: Character?) -> Bool {
        guard let previous, let next else { return false }
        if isCJK(previous) && isCJK(next) { return true }
        if isCJK(previous) && isPunctuation(next) { return true }
        if isPunctuation(previous) && isCJK(next) { return true }
        return false
    }

    private static func isCJK(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    private static func isPunctuation(_ char: Character) -> Bool {
        char.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？.!?".contains(last)
    }

    private static func endsClause(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "，、；：,;:".contains(last)
    }

    /// Format an elapsed-seconds duration for display in chat / log
    /// lines. Sub-minute durations render with one decimal (`"10.6s"`);
    /// longer ones drop the decimal and add a minutes prefix
    /// (`"9m 12s"`) so the trail stays readable for long
    /// transcription passes.
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }
}
