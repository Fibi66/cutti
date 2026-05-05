import XCTest
import CuttiKit
@testable import CuttiMac

/// Regression tests for the bilingual-subtitle pipeline. Covers the
/// four code-review blockers / should-fixes:
///
/// * B1 — `rebuildComposedSubtitles` must propagate
///   `SubtitleEntry.translations` into `ComposedSubtitle.translations`
///   so the preview overlay and burn-in renderer can see them.
/// * B2 — `translate_subtitles` write-back must address cues by UUID,
///   not by index, so a cue deleted during the network await doesn't
///   corrupt other cues.
/// * S2 — `BilingualDisplayOptions.normalizeLocale` is idempotent and
///   asymmetry-proof: translate-tool writes and style-patch reads
///   land on the same dictionary key regardless of input casing.
/// * S4 — `SubtitleStylePatch.applyReporting` surfaces a warning when
///   bilingual is explicitly enabled but no secondary locale is
///   supplied, instead of silently skipping.
@MainActor
final class BilingualSubtitleTests: XCTestCase {

    // MARK: - B1: rebuildComposedSubtitles propagates translations

    func test_rebuildComposedSubtitles_propagatesTranslationsOntoComposedCues() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let cueA = UUID()
        let cueB = UUID()
        let entries = [
            SubtitleEntry(
                id: cueA,
                relativeStart: 0,
                relativeDuration: 1,
                text: "Hello",
                translations: ["zh-Hans": "你好"]
            ),
            SubtitleEntry(
                id: cueB,
                relativeStart: 1,
                relativeDuration: 1,
                text: "World",
                translations: ["zh-Hans": "世界", "ja": "世界"]
            ),
        ]
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 2),
                text: "Hello World",
                subtitles: entries
            )
        ]

        vm.rebuildComposedSubtitles()

        XCTAssertEqual(vm.composedSubtitles.count, 2)
        let first = vm.composedSubtitles.first { $0.id == cueA }
        let second = vm.composedSubtitles.first { $0.id == cueB }
        XCTAssertEqual(first?.translations["zh-Hans"], "你好")
        XCTAssertEqual(second?.translations["zh-Hans"], "世界")
        XCTAssertEqual(second?.translations["ja"], "世界")
    }

    // MARK: - B2: write-back by UUID survives mid-await mutation

    func test_mergeSubtitleTranslations_writesByIDAndIgnoresDeletedCues() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let keep = UUID()
        let deleted = UUID()
        let later = UUID()

        // Snapshot fed into translate: three cues across one segment.
        _ = [
            SubtitleEntry(id: keep, relativeStart: 0, relativeDuration: 1, text: "A"),
            SubtitleEntry(id: deleted, relativeStart: 1, relativeDuration: 1, text: "B"),
            SubtitleEntry(id: later, relativeStart: 2, relativeDuration: 1, text: "C"),
        ]

        // Simulated post-await timeline: `deleted` cue gone, `later`
        // moved into a new split segment.
        let firstSegment = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 2),
            text: "A",
            subtitles: [
                SubtitleEntry(id: keep, relativeStart: 0, relativeDuration: 1, text: "A")
            ]
        )
        let secondSegment = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 2, endSeconds: 3),
            text: "C",
            subtitles: [
                SubtitleEntry(id: later, relativeStart: 0, relativeDuration: 1, text: "C")
            ]
        )

        let translations: [UUID: String] = [
            keep: "甲",
            deleted: "乙",
            later: "丙",
        ]

        let merge = vm.mergeSubtitleTranslations(
            into: [firstSegment, secondSegment],
            translations: translations,
            locale: "zh-Hans"
        )

        XCTAssertEqual(merge.writeCount, 2)
        XCTAssertEqual(merge.missingCount, 1)

        // `keep` got its translation in the first segment.
        XCTAssertEqual(
            merge.segments[0].subtitles.first { $0.id == keep }?.translations["zh-Hans"],
            "甲"
        )
        // `later` got its translation in the NEW (second) segment
        // even though the input candidates treated them as one list.
        XCTAssertEqual(
            merge.segments[1].subtitles.first { $0.id == later }?.translations["zh-Hans"],
            "丙"
        )
        // `deleted` is gone — no crash, no write.
        let allEntries = merge.segments.flatMap(\.subtitles)
        XCTAssertFalse(allEntries.contains { $0.id == deleted })
    }

    func test_mergeSubtitleTranslations_preservesExistingTranslationsForOtherLocales() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let id = UUID()
        let segment = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 1),
            text: "A",
            subtitles: [
                SubtitleEntry(
                    id: id,
                    relativeStart: 0,
                    relativeDuration: 1,
                    text: "A",
                    translations: ["ja": "あ"]
                )
            ]
        )

        let merge = vm.mergeSubtitleTranslations(
            into: [segment],
            translations: [id: "甲"],
            locale: "zh-Hans"
        )

        let subtitle = merge.segments[0].subtitles[0]
        XCTAssertEqual(subtitle.translations["ja"], "あ")
        XCTAssertEqual(subtitle.translations["zh-Hans"], "甲")
    }

    // MARK: - S2: locale normalization symmetry

    func test_normalizeLocale_isIdempotentAcrossCommonVariants() {
        let hans1 = BilingualDisplayOptions.normalizeLocale("zh-Hans")
        let hans2 = BilingualDisplayOptions.normalizeLocale("zh-hans")
        let hans3 = BilingualDisplayOptions.normalizeLocale("zh_Hans")
        let hans4 = BilingualDisplayOptions.normalizeLocale("  zh-Hans  ")

        XCTAssertEqual(hans1, hans2)
        XCTAssertEqual(hans2, hans3)
        XCTAssertEqual(hans3, hans4)
        // Idempotent: feeding the output back through yields the same
        // string.
        XCTAssertEqual(BilingualDisplayOptions.normalizeLocale(hans1), hans1)
    }

    func test_normalizeLocale_preservesExoticInputWhenAppleReturnsEmpty() {
        // Empty input round-trips to empty — we don't invent a locale.
        XCTAssertEqual(BilingualDisplayOptions.normalizeLocale(""), "")
        XCTAssertEqual(BilingualDisplayOptions.normalizeLocale("   "), "")
    }

    func test_subtitleStylePatch_normalizesSecondaryLocaleForLookup() {
        // Patch uses `zh-hans` (wrong casing); translations stored
        // under `zh-Hans`. After `applied(to:)`, reading the cue's
        // translation by `style.bilingual.secondaryLocale` must hit.
        var patch = SubtitleStylePatch()
        patch.bilingualEnabled = true
        patch.bilingualPrimaryLocale = "en"
        patch.bilingualSecondaryLocale = "zh-hans"

        let applied = patch.applied(to: .default)
        guard let bilingual = applied.bilingual else {
            return XCTFail("bilingual should be populated")
        }

        // Normalization must match the translate tool's own output.
        let translateKey = TranslateSubtitlesRequest.normalize(locale: "zh-Hans")
        XCTAssertEqual(bilingual.secondaryLocale, translateKey)
    }

    // MARK: - S4: bilingual enable without secondary locale surfaces warning

    func test_applyReporting_bilingualEnabledNoSecondaryLocale_emitsWarning() {
        var patch = SubtitleStylePatch()
        patch.bilingualEnabled = true

        let report = patch.applyReporting(to: .default)
        // The silent-skip behavior still holds for rendering — we
        // leave `bilingual` nil rather than produce a broken config.
        XCTAssertNil(report.style.bilingual)
        // But we also raise an observable warning so the agent layer
        // can tell the user.
        XCTAssertEqual(report.warnings, [.bilingualEnabledWithoutSecondaryLocale])
    }

    func test_applyReporting_bilingualEnabledWithSecondaryLocale_noWarning() {
        var patch = SubtitleStylePatch()
        patch.bilingualEnabled = true
        patch.bilingualSecondaryLocale = "zh-Hans"

        let report = patch.applyReporting(to: .default)
        XCTAssertNotNil(report.style.bilingual)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func test_applyReporting_bilingualDisabled_noWarningEvenWithoutLocale() {
        var patch = SubtitleStylePatch()
        patch.bilingualEnabled = false

        let report = patch.applyReporting(to: .default)
        XCTAssertNil(report.style.bilingual)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func test_aiActionExecutor_propagatesBilingualWarning() {
        var patch = SubtitleStylePatch()
        patch.bilingualEnabled = true

        let result = AIActionExecutor.apply(
            batch: AIActionBatch(
                actions: [.setSubtitleStyle(patch: patch)],
                explanation: "turn on bilingual"
            ),
            to: [],
            baseSubtitleStyle: .default,
            transcriptLookup: { _, _ in [] }
        )

        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("secondary locale"))
    }

    // MARK: - End-to-end: style patch + translations render bilingual line

    func test_currentSubtitleSecondaryText_returnsTranslationWhenStyleAndEntryAgree() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        // Style was set via a patch carrying lowercase `zh-hans` — the
        // agent's LLM might emit any casing.
        var patch = SubtitleStylePatch()
        patch.bilingualEnabled = true
        patch.bilingualSecondaryLocale = "zh-hans"
        vm.subtitleStyle = patch.applied(to: .default)

        // Translations were written by the translate tool under the
        // canonical form.
        let id = UUID()
        let canonicalKey = TranslateSubtitlesRequest.normalize(locale: "zh-Hans")
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 1),
                text: "Hello",
                subtitles: [
                    SubtitleEntry(
                        id: id,
                        relativeStart: 0,
                        relativeDuration: 1,
                        text: "Hello",
                        translations: [canonicalKey: "你好"]
                    )
                ]
            )
        ]
        vm.rebuildComposedSubtitles()

        let secondary = vm.currentSubtitleSecondaryText(at: 0.5)
        XCTAssertEqual(secondary, "你好")
    }

    // MARK: - Edit data-loss regression

    /// `updateSubtitleText` used to construct a fresh `SubtitleEntry`
    /// with only `text`, silently dropping `translations`, `speakerID`,
    /// and per-run/word-timing metadata. The user complaint was: edit
    /// the source line via double-click and the AI translation
    /// disappears. Lock that behaviour in.
    func test_updateSubtitleText_preservesTranslationsAndSpeaker() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let id = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 1),
                text: "Hello",
                subtitles: [
                    SubtitleEntry(
                        id: id,
                        relativeStart: 0,
                        relativeDuration: 1,
                        text: "Hello",
                        speakerID: 2,
                        translations: ["zh-Hans": "你好", "ja": "こんにちは"]
                    )
                ]
            )
        ]

        vm.updateSubtitleText(id: id, newText: "Hello world")

        let updated = vm.timelineSegments[0].subtitles.first { $0.id == id }
        XCTAssertEqual(updated?.text, "Hello world")
        XCTAssertEqual(updated?.speakerID, 2)
        XCTAssertEqual(updated?.translations["zh-Hans"], "你好")
        XCTAssertEqual(updated?.translations["ja"], "こんにちは")
    }

    /// The runs invariant requires `plainText(runs) == text`. When the
    /// source text actually changes, `runs` and `wordTimings` must be
    /// reset to nil — they're tied byte-for-byte to the old text.
    func test_updateSubtitleText_resetsRunsAndWordTimingsWhenTextChanges() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let id = UUID()
        let runs: [SubtitleRun] = [
            SubtitleRun(text: "Hello", style: SubtitleRunStyle())
        ]
        let timings: [WordTiming] = [
            WordTiming(text: "Hello", startSeconds: 0, endSeconds: 1)
        ]
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 1),
                text: "Hello",
                subtitles: [
                    SubtitleEntry(
                        id: id,
                        relativeStart: 0,
                        relativeDuration: 1,
                        text: "Hello",
                        runs: runs,
                        wordTimings: timings
                    )
                ]
            )
        ]

        vm.updateSubtitleText(id: id, newText: "Goodbye")

        let updated = vm.timelineSegments[0].subtitles.first { $0.id == id }
        XCTAssertEqual(updated?.text, "Goodbye")
        XCTAssertNil(updated?.runs)
        XCTAssertNil(updated?.wordTimings)
    }

    // MARK: - Bilingual edit method

    func test_updateSubtitleBilingualText_updatesPrimaryAndSecondary() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let id = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 1),
                text: "Hello",
                subtitles: [
                    SubtitleEntry(
                        id: id,
                        relativeStart: 0,
                        relativeDuration: 1,
                        text: "Hello",
                        translations: ["zh-Hans": "你好"]
                    )
                ]
            )
        ]

        vm.updateSubtitleBilingualText(
            id: id,
            primaryText: "Hello world",
            secondaryText: "你好世界",
            secondaryLocale: "zh-Hans"
        )

        let updated = vm.timelineSegments[0].subtitles.first { $0.id == id }
        XCTAssertEqual(updated?.text, "Hello world")
        XCTAssertEqual(updated?.translations["zh-Hans"], "你好世界")
    }

    /// The bilingual editor lets the user blank the secondary field to
    /// drop a bad AI translation. Empty trimmed secondary must remove
    /// THAT locale's key, leaving other locales' translations alone.
    func test_updateSubtitleBilingualText_emptySecondaryClearsLocaleKey() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let id = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 1),
                text: "Hello",
                subtitles: [
                    SubtitleEntry(
                        id: id,
                        relativeStart: 0,
                        relativeDuration: 1,
                        text: "Hello",
                        translations: ["zh-Hans": "你好", "ja": "こんにちは"]
                    )
                ]
            )
        ]

        vm.updateSubtitleBilingualText(
            id: id,
            primaryText: "Hello",
            secondaryText: "   ",
            secondaryLocale: "zh-Hans"
        )

        let updated = vm.timelineSegments[0].subtitles.first { $0.id == id }
        XCTAssertEqual(updated?.text, "Hello")
        XCTAssertNil(updated?.translations["zh-Hans"])
        XCTAssertEqual(updated?.translations["ja"], "こんにちは")
    }

    /// Translation-only edit (primary unchanged) must NOT destroy
    /// `runs`, `wordTimings`, or `speakerID` — they only depend on the
    /// source text. This is the behaviour that lets a user fix the AI
    /// translation without losing emphasis they applied earlier.
    func test_updateSubtitleBilingualText_translationOnlyEditPreservesMetadata() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let id = UUID()
        let runs: [SubtitleRun] = [
            SubtitleRun(text: "Hello", style: SubtitleRunStyle())
        ]
        let timings: [WordTiming] = [
            WordTiming(text: "Hello", startSeconds: 0, endSeconds: 1)
        ]
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 1),
                text: "Hello",
                subtitles: [
                    SubtitleEntry(
                        id: id,
                        relativeStart: 0,
                        relativeDuration: 1,
                        text: "Hello",
                        speakerID: 1,
                        translations: ["zh-Hans": "你好"],
                        runs: runs,
                        wordTimings: timings
                    )
                ]
            )
        ]

        vm.updateSubtitleBilingualText(
            id: id,
            primaryText: "Hello",
            secondaryText: "你好啊",
            secondaryLocale: "zh-Hans"
        )

        let updated = vm.timelineSegments[0].subtitles.first { $0.id == id }
        XCTAssertEqual(updated?.text, "Hello")
        XCTAssertEqual(updated?.translations["zh-Hans"], "你好啊")
        XCTAssertEqual(updated?.speakerID, 1)
        XCTAssertEqual(updated?.runs?.count, 1)
        XCTAssertEqual(updated?.wordTimings?.count, 1)
    }

    func test_updateSubtitleBilingualText_emptyPrimaryIsNoop() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let id = UUID()
        let original = SubtitleEntry(
            id: id,
            relativeStart: 0,
            relativeDuration: 1,
            text: "Hello",
            translations: ["zh-Hans": "你好"]
        )
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 1),
                text: "Hello",
                subtitles: [original]
            )
        ]

        vm.updateSubtitleBilingualText(
            id: id,
            primaryText: "   ",
            secondaryText: "ignored",
            secondaryLocale: "zh-Hans"
        )

        let after = vm.timelineSegments[0].subtitles.first { $0.id == id }
        XCTAssertEqual(after?.text, "Hello")
        XCTAssertEqual(after?.translations["zh-Hans"], "你好")
    }

    /// Locale strings flowing in from the editor (snapshotted from
    /// `style.bilingual.secondaryLocale`) might not be canonicalised.
    /// The VM normalises with `BilingualDisplayOptions.normalizeLocale`
    /// before writing so a `zh-hans` editor session lands on the same
    /// key (`zh-Hans`) the translate tool used.
    func test_updateSubtitleBilingualText_normalizesLocaleBeforeWriting() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let id = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 1),
                text: "Hello",
                subtitles: [
                    SubtitleEntry(
                        id: id,
                        relativeStart: 0,
                        relativeDuration: 1,
                        text: "Hello",
                        translations: ["zh-Hans": "你好"]
                    )
                ]
            )
        ]

        vm.updateSubtitleBilingualText(
            id: id,
            primaryText: "Hello",
            secondaryText: "你好世界",
            secondaryLocale: "zh-hans"
        )

        let updated = vm.timelineSegments[0].subtitles.first { $0.id == id }
        let canonical = BilingualDisplayOptions.normalizeLocale("zh-hans")
        XCTAssertEqual(updated?.translations[canonical], "你好世界")
    }

    /// `replaceSubtitleText` had the same data-loss bug as
    /// `updateSubtitleText`. Lock the fix in: a find/replace that
    /// changes the source line must keep translations + speaker.
    func test_replaceSubtitleText_preservesTranslationsAndSpeaker() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let id = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 1),
                text: "Hello world",
                subtitles: [
                    SubtitleEntry(
                        id: id,
                        relativeStart: 0,
                        relativeDuration: 1,
                        text: "Hello world",
                        speakerID: 7,
                        translations: ["zh-Hans": "你好世界"]
                    )
                ]
            )
        ]

        let count = vm.replaceSubtitleText(find: "world", replace: "earth", caseSensitive: false)
        XCTAssertEqual(count, 1)

        let updated = vm.timelineSegments[0].subtitles.first { $0.id == id }
        XCTAssertEqual(updated?.text, "Hello earth")
        XCTAssertEqual(updated?.speakerID, 7)
        XCTAssertEqual(updated?.translations["zh-Hans"], "你好世界")
    }

    /// `moveSubtitle` rewrites the cue with a new start/duration. It
    /// must NOT drop the translation or speaker tag in the process —
    /// dragging a bilingual cue 1cm sideways used to wipe the AI
    /// translation. Same data-loss class as `updateSubtitleText`.
    func test_moveSubtitle_preservesTranslationsAndSpeaker() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let id = UUID()
        let videoID = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: videoID,
                range: TimeRange(startSeconds: 0, endSeconds: 5),
                text: "Hello",
                subtitles: [
                    SubtitleEntry(
                        id: id,
                        relativeStart: 0,
                        relativeDuration: 1,
                        text: "Hello",
                        speakerID: 3,
                        translations: ["zh-Hans": "你好"]
                    )
                ]
            )
        ]
        vm.moveSubtitle(id: id, to: 2.0)

        let updated = vm.timelineSegments
            .flatMap(\.subtitles)
            .first { $0.id == id }
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.text, "Hello")
        XCTAssertEqual(updated?.speakerID, 3)
        XCTAssertEqual(updated?.translations["zh-Hans"], "你好")
    }
}
