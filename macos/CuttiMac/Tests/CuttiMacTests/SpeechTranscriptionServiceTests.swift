import XCTest
@testable import CuttiMac

final class SpeechTranscriptionServiceTests: XCTestCase {
    func test_resolvedSpeechProfile_defaultsToWhisper_forChinese() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(EditorLanguagePreference.chinese.rawValue, forKey: CuttiSettings.editorLanguageKey)

        let profile = CuttiSettings.resolvedSpeechProfile(
            defaults: defaults,
            fallbackLocale: Locale(identifier: "en-US")
        )

        // Whisper is now the primary backend for every language —
        // Apple SFSpeech accumulates per-segment timing drift on long
        // Chinese files which made the editor's subtitle timing drift
        // by several seconds in the final cut. See
        // `EditorLanguagePreference.resolvedPrimaryBackend` for the
        // full rationale.
        XCTAssertEqual(profile.primaryBackend, .whisperKit)
        XCTAssertEqual(profile.fallbackBackend, .appleSpeech)
        XCTAssertEqual(profile.whisperLanguageCode, "zh")
    }

    func test_resolvedSpeechProfile_defaultsToWhisper_forEnglish() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(EditorLanguagePreference.english.rawValue, forKey: CuttiSettings.editorLanguageKey)

        let profile = CuttiSettings.resolvedSpeechProfile(
            defaults: defaults,
            fallbackLocale: Locale(identifier: "zh-CN")
        )

        XCTAssertEqual(profile.primaryBackend, .whisperKit)
        XCTAssertEqual(profile.fallbackBackend, .appleSpeech)
        XCTAssertEqual(profile.whisperLanguageCode, "en")
    }

    func test_resolvedSpeechProfile_automaticUsesFallbackLocale() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(EditorLanguagePreference.automatic.rawValue, forKey: CuttiSettings.editorLanguageKey)

        // Whisper is now the primary backend regardless of the
        // fallback locale; both Chinese-leaning and English-leaning
        // automatic profiles route to WhisperKit first. The locale
        // still drives `whisperLanguageCode` so Whisper is told which
        // language to expect.
        let chineseProfile = CuttiSettings.resolvedSpeechProfile(
            defaults: defaults,
            fallbackLocale: Locale(identifier: "zh-CN")
        )
        XCTAssertEqual(chineseProfile.primaryBackend, .whisperKit)

        let englishProfile = CuttiSettings.resolvedSpeechProfile(
            defaults: defaults,
            fallbackLocale: Locale(identifier: "en-US")
        )
        XCTAssertEqual(englishProfile.primaryBackend, .whisperKit)
    }

    func test_cleanTranscriptText_removesWhisperControlTokens() {
        let raw = "<|startoftranscript|><|zh|><|transcribe|><|0.00|>反问面试官问题呢<|6.96|> <|6.96|>也是面试环节中的很大一个<|9.48|>"

        let cleaned = SpeechTranscriptionService.cleanTranscriptText(raw)

        XCTAssertFalse(cleaned.contains("<|"))
        XCTAssertEqual(cleaned, "反问面试官问题呢 也是面试环节中的很大一个")
    }

    func test_expandTimingText_splitsCompactChinesePhraseIntoMultipleTimingTokens() {
        let expanded = SpeechTranscriptionService.expandTimingText(
            "反问面试官问题呢",
            start: 0.0,
            end: 1.2,
            languageCode: "zh"
        )

        XCTAssertGreaterThan(expanded.count, 1)
        XCTAssertEqual(try XCTUnwrap(expanded.first).startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(expanded.last).endSeconds, 1.2, accuracy: 0.001)
        XCTAssertTrue(expanded.allSatisfy { !$0.text.isEmpty })
    }
}
