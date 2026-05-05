import XCTest
import CuttiKit
@testable import CuttiMac

/// V1 of per-cue subtitle style override added a new metadata field to
/// `SubtitleEntry`. This file pins down the audit guarantee: every code
/// path that *transforms* an existing cue (text edit, resize, move, AI
/// rewrite, replace, segment split, segment merge, tombstone restore,
/// etc.) preserves `styleOverride`. Without these tests, future struct
/// fields are likely to silently drop again — that bug class drove the
/// per-cue-style scoping work in the first place.
@MainActor
final class SubtitleStyleOverrideSurvivalTests: XCTestCase {

    private let override = SubtitleCueStyleOverride(
        fontSizePoints: 70,
        textColor: SubtitleStyle.RGBAColor(red: 1, green: 0.85, blue: 0.08, alpha: 1),
        backgroundColor: .black,
        cornerRadius: 12
    )

    private func makeVM(with subtitles: [SubtitleEntry], speed: Double = 1.0) -> MediaCoreViewModel {
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            projectRoot: URL(fileURLWithPath: "/project")
        )
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 30),
                text: subtitles.map(\.text).joined(separator: " "),
                subtitles: subtitles,
                speedRate: speed
            )
        ]
        return vm
    }

    private func cue(for id: UUID, in vm: MediaCoreViewModel) -> SubtitleEntry? {
        vm.timelineSegments.flatMap(\.subtitles).first { $0.id == id }
    }

    // MARK: - Text-mutating paths

    func test_updateSubtitleText_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 2, text: "hello",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.updateSubtitleText(id: id, newText: "hello world")
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override)
        XCTAssertEqual(cue(for: id, in: vm)?.text, "hello world")
    }

    func test_replaceSubtitleText_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 2, text: "foo bar",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        let n = vm.replaceSubtitleText(find: "foo", replace: "FOO")
        XCTAssertEqual(n, 1)
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override)
        XCTAssertEqual(cue(for: id, in: vm)?.text, "FOO bar")
    }

    func test_updateSubtitleBilingualText_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 2, text: "hi",
            translations: ["zh-Hans": "你好"],
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.updateSubtitleBilingualText(
            id: id, primaryText: "hello", secondaryText: "你好啊", secondaryLocale: "zh-Hans"
        )
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override)
        XCTAssertEqual(cue(for: id, in: vm)?.text, "hello")
    }

    // MARK: - Time-mutating paths

    func test_moveSubtitle_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.moveSubtitle(id: id, to: 2.0)
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override)
    }

    func test_resizeSubtitle_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.resizeSubtitle(id: id, edge: .trailing, toComposedTime: 3.0)
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override)
    }

    // MARK: - Run/emphasis paths

    func test_clearEmphasisOnSubtitle_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            runs: [SubtitleRun(text: "hi", style: SubtitleRunStyle(weight: .bold))],
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        let didClear = vm.clearEmphasisOnSubtitle(cueID: id)
        XCTAssertTrue(didClear)
        XCTAssertNil(cue(for: id, in: vm)?.runs)
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override,
                       "clearing per-run emphasis must NOT touch the per-cue override")
    }

    // MARK: - Tombstone delete + restore

    func test_deleteThenRestoreSubtitle_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 2, text: "hi",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.rebuildComposedSubtitles()

        vm.deleteSubtitleCues(ids: [id])
        XCTAssertNil(cue(for: id, in: vm))
        let tomb = vm.subtitleTombstones.first { $0.id == id }
        XCTAssertEqual(tomb?.styleOverride, override,
                       "tombstone must capture override at delete time")

        vm.restoreSubtitleTombstone(id: id)
        XCTAssertEqual(cue(for: id, in: vm)?.styleOverride, override,
                       "restored cue must wear the same override it had at delete time")
    }

    // MARK: - Translation merge (write-back path)

    func test_mergeSubtitleTranslations_preservesStyleOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 2, text: "hello",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        let merge = vm.mergeSubtitleTranslations(
            into: vm.timelineSegments,
            translations: [id: "你好"],
            locale: "zh-Hans"
        )
        let merged = merge.segments.flatMap(\.subtitles).first { $0.id == id }
        XCTAssertEqual(merged?.styleOverride, override)
        XCTAssertEqual(merged?.translations["zh-Hans"], "你好")
    }

    // MARK: - effectiveSubtitleStyle

    func test_effectiveStyle_noOverride_returnsGlobal() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi"
        )
        let vm = makeVM(with: [entry])
        XCTAssertEqual(vm.effectiveSubtitleStyle(forCueID: id), vm.subtitleStyle)
    }

    func test_effectiveStyle_appliesOverrideOnTopOfGlobal() {
        let id = UUID()
        let yellow = SubtitleStyle.RGBAColor(red: 1, green: 0.85, blue: 0.08, alpha: 1)
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: SubtitleCueStyleOverride(textColor: yellow)
        )
        let vm = makeVM(with: [entry])
        let effective = vm.effectiveSubtitleStyle(forCueID: id)
        XCTAssertEqual(effective.textColor, yellow,
                       "override field must replace global field")
        XCTAssertEqual(effective.fontSizePoints, vm.subtitleStyle.fontSizePoints,
                       "non-override fields must come from global")
    }

    func test_effectiveStyle_unknownCueID_returnsGlobal() {
        let vm = makeVM(with: [])
        XCTAssertEqual(vm.effectiveSubtitleStyle(forCueID: UUID()), vm.subtitleStyle)
    }

    // MARK: - applySubtitleStylePatch (per-cue)

    func test_applyPatchToCue_writesOverride() {
        let id = UUID()
        let entry = SubtitleEntry(id: id, relativeStart: 0, relativeDuration: 1, text: "hi")
        let vm = makeVM(with: [entry])
        let patch = SubtitleStylePatch(fontSizePoints: 70)
        vm.applySubtitleStylePatch(patch, toCueID: id, commit: true)
        let cue = vm.subtitleEntry(forID: id)
        XCTAssertEqual(cue?.styleOverride?.fontSizePoints, 70,
                       "override should carry the diverging field")
        XCTAssertEqual(vm.subtitleStyle.fontSizePoints,
                       MediaCoreViewModel(playbackCore: SpyPlaybackCore(),
                                          projectRoot: URL(fileURLWithPath: "/")).subtitleStyle.fontSizePoints,
                       "global must NOT be touched")
    }

    func test_applyPatchToCue_layersOnTopOfExistingOverride() {
        let id = UUID()
        let yellow = SubtitleStyle.RGBAColor(red: 1, green: 0.85, blue: 0.08, alpha: 1)
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: SubtitleCueStyleOverride(textColor: yellow)
        )
        let vm = makeVM(with: [entry])
        vm.applySubtitleStylePatch(SubtitleStylePatch(fontSizePoints: 64),
                                   toCueID: id, commit: true)
        let override = vm.subtitleEntry(forID: id)?.styleOverride
        XCTAssertEqual(override?.textColor, yellow, "preexisting override field stays")
        XCTAssertEqual(override?.fontSizePoints, 64, "new field is added")
    }

    func test_applyPatchToCue_settingValueBackToGlobal_clearsThatField() {
        let id = UUID()
        let globalSize = SubtitleStyle.default.fontSizePoints
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: SubtitleCueStyleOverride(fontSizePoints: 70)
        )
        let vm = makeVM(with: [entry])
        // Drag back to global font size — the override field should clear.
        vm.applySubtitleStylePatch(
            SubtitleStylePatch(fontSizePoints: globalSize),
            toCueID: id, commit: true
        )
        let override = vm.subtitleEntry(forID: id)?.styleOverride
        XCTAssertNil(override?.fontSizePoints,
                     "value matching global should clear from override")
    }

    func test_applyPatchToCue_emptyAfterDiff_collapsesToNil() {
        let id = UUID()
        let globalSize = SubtitleStyle.default.fontSizePoints
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: SubtitleCueStyleOverride(fontSizePoints: 70)
        )
        let vm = makeVM(with: [entry])
        vm.applySubtitleStylePatch(
            SubtitleStylePatch(fontSizePoints: globalSize),
            toCueID: id, commit: true
        )
        XCTAssertNil(vm.subtitleEntry(forID: id)?.styleOverride,
                     "empty override must collapse to nil so the cue stops being 'Customized'")
    }

    // MARK: - applySelectedCueStyleToAllCues

    func test_applyToAll_promotesEffectiveAndWipesOtherOverrides() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let yellow = SubtitleStyle.RGBAColor(red: 1, green: 0.85, blue: 0.08, alpha: 1)
        let red = SubtitleStyle.RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        let cues = [
            SubtitleEntry(id: a, relativeStart: 0, relativeDuration: 1, text: "A",
                          styleOverride: SubtitleCueStyleOverride(textColor: yellow)),
            SubtitleEntry(id: b, relativeStart: 1, relativeDuration: 1, text: "B",
                          styleOverride: SubtitleCueStyleOverride(textColor: red)),
            SubtitleEntry(id: c, relativeStart: 2, relativeDuration: 1, text: "C")
        ]
        let vm = makeVM(with: cues)
        vm.selectedSubtitleID = a
        let didApply = vm.applySelectedCueStyleToAllCues()
        XCTAssertTrue(didApply)
        XCTAssertEqual(vm.subtitleStyle.textColor, yellow,
                       "selected cue's override field promoted to global")
        XCTAssertNil(vm.subtitleEntry(forID: a)?.styleOverride, "selected cue's override cleared")
        XCTAssertNil(vm.subtitleEntry(forID: b)?.styleOverride, "other cue's override wiped too")
        XCTAssertNil(vm.subtitleEntry(forID: c)?.styleOverride, "vanilla cue stays nil")
    }

    func test_applyToAll_noSelection_returnsFalse() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.selectedSubtitleID = nil
        XCTAssertFalse(vm.applySelectedCueStyleToAllCues())
    }

    func test_applyToAll_selectedCueHasNoOverride_returnsFalse() {
        let id = UUID()
        let entry = SubtitleEntry(id: id, relativeStart: 0, relativeDuration: 1, text: "hi")
        let vm = makeVM(with: [entry])
        vm.selectedSubtitleID = id
        XCTAssertFalse(vm.applySelectedCueStyleToAllCues(),
                       "no override → no-op")
    }

    // MARK: - resetSelectedCueStyleOverride

    func test_resetSelectedCueOverride_clearsOverride() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.selectedSubtitleID = id
        XCTAssertTrue(vm.resetSelectedCueStyleOverride())
        XCTAssertNil(vm.subtitleEntry(forID: id)?.styleOverride)
    }

    func test_resetSelectedCueOverride_noSelection_returnsFalse() {
        let id = UUID()
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: override
        )
        let vm = makeVM(with: [entry])
        vm.selectedSubtitleID = nil
        XCTAssertFalse(vm.resetSelectedCueStyleOverride())
    }

    func test_resetSelectedCueOverride_noOverride_returnsFalse() {
        let id = UUID()
        let entry = SubtitleEntry(id: id, relativeStart: 0, relativeDuration: 1, text: "hi")
        let vm = makeVM(with: [entry])
        vm.selectedSubtitleID = id
        XCTAssertFalse(vm.resetSelectedCueStyleOverride())
    }

    // MARK: - cueHasStyleOverride

    func test_cueHasStyleOverride_reflectsOverrideState() {
        let withOverride = UUID()
        let withoutOverride = UUID()
        let cues = [
            SubtitleEntry(id: withOverride, relativeStart: 0, relativeDuration: 1, text: "A",
                          styleOverride: override),
            SubtitleEntry(id: withoutOverride, relativeStart: 1, relativeDuration: 1, text: "B")
        ]
        let vm = makeVM(with: cues)
        XCTAssertTrue(vm.cueHasStyleOverride(withOverride))
        XCTAssertFalse(vm.cueHasStyleOverride(withoutOverride))
        XCTAssertFalse(vm.cueHasStyleOverride(UUID()), "unknown id must not crash")
    }

    // MARK: - Undo correctness for "Apply to all" (revision restore)

    func test_undoApplyToAll_restoresGlobalStyleAndPerCueOverride() {
        let id = UUID()
        let yellow = SubtitleStyle.RGBAColor(red: 1, green: 0.85, blue: 0.08, alpha: 1)
        let entry = SubtitleEntry(
            id: id, relativeStart: 0, relativeDuration: 1, text: "hi",
            styleOverride: SubtitleCueStyleOverride(textColor: yellow)
        )
        let vm = makeVM(with: [entry])
        vm.selectedSubtitleID = id
        let beforeGlobalColor = vm.subtitleStyle.textColor

        XCTAssertTrue(vm.applySelectedCueStyleToAllCues())
        XCTAssertEqual(vm.subtitleStyle.textColor, yellow)
        XCTAssertNil(vm.subtitleEntry(forID: id)?.styleOverride)

        vm.undo()
        XCTAssertEqual(vm.subtitleStyle.textColor, beforeGlobalColor,
                       "Cmd+Z must restore the previous global style")
        XCTAssertEqual(vm.subtitleEntry(forID: id)?.styleOverride?.textColor, yellow,
                       "Cmd+Z must restore the per-cue override")
    }
}
