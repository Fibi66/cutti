import AVFoundation
import Foundation
import NaturalLanguage
import Speech
import WhisperKit
import CuttiKit

/// Transcribes audio from a video file.
///
/// Chooses the default speech backend from app settings, using Apple Speech
/// first for Chinese and Whisper first for English by default.
struct SpeechTranscriptionService: Sendable {
    struct Result: Sendable {
        /// Cleaned higher-level transcript segments for display/debugging.
        let displaySegments: [TranscriptSegment]
        /// Best available token/word-level timings for downstream silence trimming.
        let wordSegments: [TranscriptSegment]
    }

    enum TranscriptionError: Error, Sendable {
        case recognizerUnavailable
        case authorizationDenied
        case noResult
        case recognitionFailed(String)
    }

    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    // MARK: - Public

    func transcribe(url: URL, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let profile = CuttiSettings.resolvedSpeechProfile(
            defaults: .standard,
            fallbackLocale: locale
        )
        var lastError: Error?

        for (index, backend) in [profile.primaryBackend, profile.fallbackBackend].enumerated() {
            do {
                let result = try await transcribe(
                    url: url,
                    with: backend,
                    profile: profile,
                    onProgress: onProgress
                )
                if !result.displaySegments.isEmpty || !result.wordSegments.isEmpty {
                    return result
                }
                lastError = TranscriptionError.noResult
                print("🎤 \(backend.title) returned no transcript")
            } catch {
                lastError = error
                print("🎤 \(backend.title) failed: \(error.localizedDescription)")
            }

            if index == 0 {
                print("🎤 Falling back to \(profile.fallbackBackend.title)")
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
        case .whisperKit:
            onProgress?("Transcribing with Whisper…")
            return try await transcribeWithWhisperKit(
                url: url,
                languageCode: profile.whisperLanguageCode,
                onProgress: onProgress
            )
        case .appleSpeech:
            onProgress?("Transcribing with Apple Speech…")
            let segments = try await transcribeWithSFSpeech(url: url, locale: profile.locale)
            return Result(displaySegments: segments, wordSegments: segments)
        }
    }

    // MARK: - WhisperKit (native Swift, CoreML)

    private func transcribeWithWhisperKit(
        url: URL,
        languageCode lang: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> Result {
        onProgress?("Loading Whisper model (first time downloads ~1.5GB)…")
        print("🎤 WhisperKit: loading model...")

        let whisper = try await WhisperKit(
            model: "openai_whisper-large-v3-v20240930_turbo",
            verbose: false,
            logLevel: .none
        )

        onProgress?("Transcribing audio with Whisper…")
        print("🎤 WhisperKit: transcribing \(url.lastPathComponent) (lang=\(lang))...")

        let results = try await whisper.transcribe(
            audioPath: url.path,
            decodeOptions: DecodingOptions(
                language: lang,
                wordTimestamps: true
            )
        )

        // Collect both timing-level and segment-level transcriptions.
        // For Chinese, Whisper's "word" timestamps can still be phrase-sized,
        // so we further expand them into smaller lexical tokens.
        var wordSegments: [TranscriptSegment] = []
        var sentenceSegments: [TranscriptSegment] = []

        for result in results {
            for seg in result.segments {
                // Collect sentence-level
                let segText = Self.cleanTranscriptText(seg.text)
                if !segText.isEmpty && seg.end - seg.start > 0.01 {
                    sentenceSegments.append(TranscriptSegment(
                        startSeconds: Double(seg.start),
                        endSeconds: Double(seg.end),
                        text: segText
                    ))
                }

                // Collect word-level
                if let words = seg.words {
                    for timing in words {
                        wordSegments.append(contentsOf: Self.expandTimingText(
                            timing.word,
                            start: Double(timing.start),
                            end: Double(timing.end),
                            languageCode: lang
                        ))
                    }
                }
            }
        }

        let timingSegments = wordSegments.isEmpty ? sentenceSegments : wordSegments
        let displaySegments = sentenceSegments.isEmpty
            ? Self.groupTimingSegmentsForDisplay(timingSegments)
            : sentenceSegments

        print("🎤 WhisperKit: using sentence display (\(displaySegments.count)) + timing tokens (\(timingSegments.count))")

        print("🎤 WhisperKit: display=\(displaySegments.count) timing=\(timingSegments.count)")
        if let first = displaySegments.first {
            print("🎤   first: t=\(String(format: "%.2f", first.startSeconds))s end=\(String(format: "%.2f", first.endSeconds))s \"\(first.text)\"")
        }
        if let last = displaySegments.last {
            print("🎤   last:  t=\(String(format: "%.2f", last.startSeconds))s end=\(String(format: "%.2f", last.endSeconds))s \"\(last.text)\"")
        }

        return Result(displaySegments: displaySegments, wordSegments: timingSegments)
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

        // SFSpeech for Chinese systematically under-reports per-word
        // `duration`: the reported end often lands mid-way through the
        // final syllable's phoneme, so a cut at that boundary lops off
        // the last character's audio. Pad each word's end, clamped by
        // the next word's start (minus a tiny epsilon so the two don't
        // meet exactly) to avoid bleeding. The clamp means we only
        // actually consume the full pad at sentence boundaries / long
        // pauses — which is exactly where the tail truncation is worst.
        // 500ms preserves most of the Chinese declarative tail without
        // leaving long trailing dead air in the final cut.
        let tailPad: Double = 0.5
        let tailEpsilon: Double = 0.02
        var addedPadTotalMs: Double = 0
        var maxPadMs: Double = 0
        let padded: [TranscriptSegment] = rawSegments.enumerated().map { index, seg in
            let rawEnd = seg.timestamp + seg.duration
            let ceiling: Double
            if index + 1 < rawSegments.count {
                ceiling = max(rawEnd, rawSegments[index + 1].timestamp - tailEpsilon)
            } else {
                ceiling = .infinity
            }
            let paddedEnd = min(rawEnd + tailPad, ceiling)
            let padMs = (paddedEnd - rawEnd) * 1000
            addedPadTotalMs += padMs
            maxPadMs = max(maxPadMs, padMs)
            return TranscriptSegment(
                startSeconds: seg.timestamp,
                endSeconds: paddedEnd,
                text: seg.substring
            )
        }
        let avgPadMs = rawSegments.isEmpty ? 0 : addedPadTotalMs / Double(rawSegments.count)
        print(String(
            format: "🎤 Chinese tail-pad applied: target=%.0fms, avg added=%.0fms, max added=%.0fms across %d words",
            tailPad * 1000, avgPadMs, maxPadMs, rawSegments.count
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
}
