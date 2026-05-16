import XCTest
@testable import CuttiMac

final class SpeechTranscriptionServiceTests: XCTestCase {
    // MARK: - Pure resolver matrix
    //
    // The resolver decides which backends sit in
    // `SpeechRecognitionProfile.backendChain` based on host
    // capabilities (direct distribution / Apple Silicon / Qwen
    // installed). Exercising the pure resolver lets us check every
    // branch without touching the real disk install state — important
    // because clean CI hosts will never have the 6 GB Qwen install
    // and would otherwise always resolve to Apple Speech.

    func test_resolveSpeechProfile_directAppleSiliconWithQwen_routesToQwenFirst() {
        let caps = SpeechResolverCapabilities(
            isDirectDistribution: true,
            isAppleSilicon: true,
            qwenInstalled: true
        )

        let profile = CuttiSettings.resolveSpeechProfile(
            fallbackLocale: Locale(identifier: "zh-CN"),
            capabilities: caps
        )

        XCTAssertEqual(profile.primaryBackend, .qwenAsrSidecar)
        XCTAssertEqual(profile.fallbackBackend, .appleSpeech)
        XCTAssertEqual(profile.languageCode, "zh")
    }

    func test_resolveSpeechProfile_directAppleSiliconButQwenNotInstalled_routesToAppleSpeech() {
        let caps = SpeechResolverCapabilities(
            isDirectDistribution: true,
            isAppleSilicon: true,
            qwenInstalled: false
        )

        let profile = CuttiSettings.resolveSpeechProfile(
            fallbackLocale: Locale(identifier: "en-US"),
            capabilities: caps
        )

        // No Qwen on disk → only fallback in the chain.
        XCTAssertEqual(profile.backendChain, [.appleSpeech])
        XCTAssertEqual(profile.languageCode, "en")
    }

    func test_resolveSpeechProfile_intelHost_skipsQwenEvenWhenInstalled() {
        // Intel hosts can't run the MPS-bound aligner, so even if a
        // stale install hangs around on disk we must not list Qwen
        // in the chain.
        let caps = SpeechResolverCapabilities(
            isDirectDistribution: true,
            isAppleSilicon: false,
            qwenInstalled: true
        )

        let profile = CuttiSettings.resolveSpeechProfile(
            fallbackLocale: Locale(identifier: "zh-CN"),
            capabilities: caps
        )

        XCTAssertEqual(profile.backendChain, [.appleSpeech])
        XCTAssertEqual(profile.languageCode, "zh")
    }

    func test_resolveSpeechProfile_masDistribution_skipsQwen() {
        // Mac App Store builds can't ship the Python sidecar, so the
        // Qwen entry must never appear regardless of the on-disk
        // marker. Confirms the gate works even on Apple Silicon.
        let caps = SpeechResolverCapabilities(
            isDirectDistribution: false,
            isAppleSilicon: true,
            qwenInstalled: true
        )

        let profile = CuttiSettings.resolveSpeechProfile(
            fallbackLocale: Locale(identifier: "en-US"),
            capabilities: caps
        )

        XCTAssertEqual(profile.backendChain, [.appleSpeech])
    }

    func test_resolveSpeechProfile_cantoneseLocalePropagatesYueHint() {
        let caps = SpeechResolverCapabilities(
            isDirectDistribution: true,
            isAppleSilicon: true,
            qwenInstalled: true
        )

        let profile = CuttiSettings.resolveSpeechProfile(
            fallbackLocale: Locale(identifier: "yue-Hant-HK"),
            capabilities: caps
        )

        XCTAssertEqual(profile.languageCode, "yue")
        XCTAssertEqual(profile.primaryBackend, .qwenAsrSidecar)
    }

    // MARK: - Transcript helpers
    //
    // `cleanTranscriptText` and `expandTimingText` were originally
    // written for an external ASR's output format but are now also used
    // by the SFSpeech path to split phrase-sized substrings into
    // per-character timing tokens. Keeping the behavioural tests
    // here ensures the helpers stay correct as the surrounding
    // pipeline evolves.

    func test_cleanTranscriptText_removesAsrControlTokens() {
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
