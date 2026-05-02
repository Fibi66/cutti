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
}
