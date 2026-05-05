import XCTest
@testable import CuttiKit

final class SubtitleRunEditorTests: XCTestCase {

    // MARK: - singleRun / plainText / utf16Length

    func test_singleRun_wrapsPlainText() {
        let runs = SubtitleRunEditor.singleRun("Hello")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "Hello")
        XCTAssertEqual(runs[0].style, .empty)
    }

    func test_singleRun_emptyString_producesEmptyArray() {
        XCTAssertTrue(SubtitleRunEditor.singleRun("").isEmpty)
    }

    func test_plainText_concatenatesRunsInOrder() {
        let runs = [
            SubtitleRun(text: "Hello "),
            SubtitleRun(text: "world"),
            SubtitleRun(text: "!"),
        ]
        XCTAssertEqual(SubtitleRunEditor.plainText(runs), "Hello world!")
    }

    func test_utf16Length_matchesPlainTextLength() {
        let runs = [SubtitleRun(text: "ab"), SubtitleRun(text: "你好"), SubtitleRun(text: "c")]
        XCTAssertEqual(
            SubtitleRunEditor.utf16Length(runs),
            SubtitleRunEditor.plainText(runs).utf16.count
        )
    }

    // MARK: - split

    func test_split_atMidRunOffset_producesTwoPieces() {
        let runs = [SubtitleRun(text: "abcdef")]
        let out = SubtitleRunEditor.split(runs: runs, at: [3])
        XCTAssertEqual(out.map(\.text), ["abc", "def"])
        // Left side keeps the original id; right side gets a new one.
        XCTAssertEqual(out[0].id, runs[0].id)
        XCTAssertNotEqual(out[1].id, runs[0].id)
    }

    func test_split_atRunBoundary_isNoOp() {
        let runs = [SubtitleRun(text: "abc"), SubtitleRun(text: "def")]
        let out = SubtitleRunEditor.split(runs: runs, at: [3])
        XCTAssertEqual(out.map(\.text), ["abc", "def"])
        XCTAssertEqual(out.map(\.id), runs.map(\.id))
    }

    func test_split_atZeroOrEnd_isNoOp() {
        let runs = [SubtitleRun(text: "abcdef")]
        let out = SubtitleRunEditor.split(runs: runs, at: [0, 6, 100, -1])
        XCTAssertEqual(out.map(\.text), ["abcdef"])
        XCTAssertEqual(out.map(\.id), runs.map(\.id))
    }

    func test_split_multipleOffsets_inOneRun_producesSortedPieces() {
        let runs = [SubtitleRun(text: "abcdefgh")]
        let out = SubtitleRunEditor.split(runs: runs, at: [6, 2, 4])
        XCTAssertEqual(out.map(\.text), ["ab", "cd", "ef", "gh"])
    }

    func test_split_preservesConcatenatedText() {
        let runs = [
            SubtitleRun(text: "Hello "),
            SubtitleRun(text: "world"),
            SubtitleRun(text: "!"),
        ]
        let out = SubtitleRunEditor.split(runs: runs, at: [2, 7, 9])
        XCTAssertEqual(SubtitleRunEditor.plainText(out), "Hello world!")
    }

    func test_split_preservesStyleAcrossPieces() {
        let style = SubtitleRunStyle(
            weight: .bold, textColor: .yellow)
        let runs = [SubtitleRun(text: "abcdef", style: style)]
        let out = SubtitleRunEditor.split(runs: runs, at: [3])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].style, style)
        XCTAssertEqual(out[1].style, style)
    }

    // MARK: - applyStyle

    func test_applyStyle_wholeRange_overridesSingleRun() {
        let runs = SubtitleRunEditor.singleRun("abcdef")
        let out = SubtitleRunEditor.applyStyle(
            to: runs,
            range: 0..<6,
            patch: SubtitleRunStyle(textColor: .yellow)
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "abcdef")
        XCTAssertEqual(out[0].style.textColor, .yellow)
    }

    func test_applyStyle_partialRange_splitsAndStyles() {
        let runs = SubtitleRunEditor.singleRun("Hello world")
        let out = SubtitleRunEditor.applyStyle(
            to: runs,
            range: 6..<11,
            patch: SubtitleRunStyle(textColor: .yellow)
        )
        XCTAssertEqual(out.map(\.text), ["Hello ", "world"])
        XCTAssertNil(out[0].style.textColor)
        XCTAssertEqual(out[1].style.textColor, .yellow)
    }

    func test_applyStyle_crossingRunBoundaries_mergesConsistentStyle() {
        let runs = [
            SubtitleRun(text: "ab"),
            SubtitleRun(text: "cd"),
            SubtitleRun(text: "ef"),
        ]
        // Applying the same style across all three runs should normalize
        // back down to one run.
        let out = SubtitleRunEditor.applyStyle(
            to: runs,
            range: 0..<6,
            patch: SubtitleRunStyle(textColor: .yellow)
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "abcdef")
        XCTAssertEqual(out[0].style.textColor, .yellow)
    }

    func test_applyStyle_nilFieldsInPatch_leaveExistingFieldsAlone() {
        var style = SubtitleRunStyle(weight: .bold, textColor: .yellow)
        style.sizeMultiplier = 1.5
        let runs = [SubtitleRun(text: "abc", style: style)]
        // Patch only changes strokeColor; existing overrides must stay.
        let out = SubtitleRunEditor.applyStyle(
            to: runs,
            range: 0..<3,
            patch: SubtitleRunStyle(strokeColor: .black)
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].style.textColor, .yellow)
        XCTAssertEqual(out[0].style.weight, .bold)
        XCTAssertEqual(out[0].style.sizeMultiplier, 1.5)
        XCTAssertEqual(out[0].style.strokeColor, .black)
    }

    func test_applyStyle_emptyRange_isNoOp() {
        let runs = SubtitleRunEditor.singleRun("abcdef")
        let out = SubtitleRunEditor.applyStyle(
            to: runs,
            range: 3..<3,
            patch: SubtitleRunStyle(textColor: .yellow)
        )
        XCTAssertEqual(out, runs)
    }

    func test_applyStyle_outOfBoundsRange_isClampedThenNoOpWhenEmpty() {
        let runs = SubtitleRunEditor.singleRun("abc")
        let out = SubtitleRunEditor.applyStyle(
            to: runs,
            range: 10..<20,
            patch: SubtitleRunStyle(textColor: .yellow)
        )
        XCTAssertEqual(out, runs)
    }

    func test_applyStyle_preservesPlainText() {
        let runs = [
            SubtitleRun(text: "The "),
            SubtitleRun(text: "quick "),
            SubtitleRun(text: "brown fox"),
        ]
        let original = SubtitleRunEditor.plainText(runs)
        let out = SubtitleRunEditor.applyStyle(
            to: runs,
            range: 4..<9,
            patch: SubtitleRunStyle(weight: .bold)
        )
        XCTAssertEqual(SubtitleRunEditor.plainText(out), original)
    }

    // MARK: - setStyle (replace semantics — for clearing overrides)

    func test_setStyle_empty_clearsOverridesInRange() {
        let bold = SubtitleRunStyle(weight: .bold)
        let runs = [
            SubtitleRun(text: "abc", style: bold),
            SubtitleRun(text: "def", style: bold),
        ]
        let out = SubtitleRunEditor.setStyle(
            on: runs,
            range: 2..<5,
            style: .empty
        )
        // Expect:  "ab"=bold, "cde"=empty, "f"=bold
        XCTAssertEqual(out.map(\.text), ["ab", "cde", "f"])
        XCTAssertEqual(out[0].style, bold)
        XCTAssertEqual(out[1].style, .empty)
        XCTAssertEqual(out[2].style, bold)
    }

    // MARK: - normalize

    func test_normalize_mergesAdjacentEqualStyle() {
        let bold = SubtitleRunStyle(weight: .bold)
        let runs = [
            SubtitleRun(text: "ab", style: bold),
            SubtitleRun(text: "cd", style: bold),
            SubtitleRun(text: "ef"),
            SubtitleRun(text: "gh"),
        ]
        let out = SubtitleRunEditor.normalize(runs)
        XCTAssertEqual(out.map(\.text), ["abcd", "efgh"])
        XCTAssertEqual(out[0].style, bold)
        XCTAssertEqual(out[1].style, .empty)
    }

    func test_normalize_dropsEmptyTextRuns() {
        let runs = [
            SubtitleRun(text: "ab"),
            SubtitleRun(text: ""),
            SubtitleRun(text: "cd"),
        ]
        let out = SubtitleRunEditor.normalize(runs)
        XCTAssertEqual(out.map(\.text), ["abcd"])
    }

    // MARK: - UTF-16 / multibyte content

    func test_split_inMiddleOfChineseText_producesClean2CodeUnitBoundaries() {
        let runs = SubtitleRunEditor.singleRun("你好世界")
        // Each Chinese CJK char is 1 UTF-16 code unit (BMP).
        let out = SubtitleRunEditor.split(runs: runs, at: [2])
        XCTAssertEqual(out.map(\.text), ["你好", "世界"])
    }

    func test_applyStyle_onChineseText_stylesMatchingSubstring() {
        let runs = SubtitleRunEditor.singleRun("今天的重点是性能")
        let out = SubtitleRunEditor.applyStyle(
            to: runs,
            range: 3..<5,  // "重点"
            patch: SubtitleRunStyle(weight: .bold, textColor: .yellow)
        )
        XCTAssertEqual(out.map(\.text), ["今天的", "重点", "是性能"])
        XCTAssertEqual(out[1].style.textColor, .yellow)
        XCTAssertEqual(out[1].style.weight, .bold)
    }

    // MARK: - SubtitleRunStyle.merging / isEmpty

    func test_runStyle_empty_hasAllNilFields() {
        let s = SubtitleRunStyle.empty
        XCTAssertTrue(s.isEmpty)
    }

    func test_runStyle_merging_patchOverridesBase() {
        let base = SubtitleRunStyle(weight: .regular, textColor: .white)
        let patch = SubtitleRunStyle(textColor: .yellow)
        let merged = base.merging(patch)
        XCTAssertEqual(merged.textColor, .yellow)
        XCTAssertEqual(merged.weight, .regular)
    }

    func test_runStyle_merging_nilPatchFieldsLeaveBaseAlone() {
        let base = SubtitleRunStyle(weight: .bold, textColor: .yellow)
        let merged = base.merging(.empty)
        XCTAssertEqual(merged.textColor, .yellow)
        XCTAssertEqual(merged.weight, .bold)
    }

    // MARK: - Codable

    func test_run_codableRoundtrip_preservesStyle() throws {
        let run = SubtitleRun(
            text: "重点",
            style: SubtitleRunStyle(
                sizeMultiplier: 1.4,
                weight: .bold,
                textColor: .yellow
            )
        )
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(SubtitleRun.self, from: data)
        XCTAssertEqual(decoded, run)
    }

    func test_run_codable_emptyStyleNotEncoded_decodesAsEmpty() throws {
        let run = SubtitleRun(text: "plain")
        let data = try JSONEncoder().encode(run)
        // Ensure the 'style' key isn't in the JSON (keeps payloads lean).
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"style\""))
        let decoded = try JSONDecoder().decode(SubtitleRun.self, from: data)
        XCTAssertEqual(decoded.style, .empty)
    }

    // MARK: - SubtitleEntry round-trip via PersistableSubtitle

    func test_subtitleEntry_runs_persistAndRehydrate() throws {
        let runs: [SubtitleRun] = [
            SubtitleRun(text: "Hello "),
            SubtitleRun(
                text: "world",
                style: SubtitleRunStyle(weight: .bold, textColor: .yellow)
            ),
        ]
        let entry = SubtitleEntry(
            id: UUID(),
            relativeStart: 0,
            relativeDuration: 1.5,
            text: "Hello world",
            runs: runs
        )
        XCTAssertTrue(entry.hasConsistentRuns)

        let persistable = EditorRevision.PersistableSubtitle(from: entry)
        let data = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(
            EditorRevision.PersistableSubtitle.self, from: data)
        let roundTripped = decoded.toSubtitleEntry()

        XCTAssertEqual(roundTripped.runs, runs)
        XCTAssertEqual(roundTripped.text, "Hello world")
    }

    func test_subtitleEntry_backCompat_missingRunsField_decodesAsNil() throws {
        // Simulate an older manifest payload that predates the runs field.
        let legacyJSON = """
            {
              "id": "\(UUID().uuidString)",
              "relativeStart": 0,
              "relativeDuration": 1.5,
              "text": "legacy"
            }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(
            EditorRevision.PersistableSubtitle.self, from: legacyJSON)
        let entry = decoded.toSubtitleEntry()
        XCTAssertNil(entry.runs)
        XCTAssertNil(entry.styleOverride)
        XCTAssertEqual(entry.text, "legacy")
    }

    func test_subtitleEntry_styleOverride_persistAndRehydrate() throws {
        let override = SubtitleCueStyleOverride(
            fontSizePoints: 64,
            textColor: .yellow,
            backgroundColor: .black,
            cornerRadius: 12
        )
        let entry = SubtitleEntry(
            id: UUID(),
            relativeStart: 0,
            relativeDuration: 1.5,
            text: "highlighted",
            styleOverride: override
        )
        let data = try JSONEncoder().encode(EditorRevision.PersistableSubtitle(from: entry))
        let decoded = try JSONDecoder().decode(
            EditorRevision.PersistableSubtitle.self, from: data)
        XCTAssertEqual(decoded.toSubtitleEntry().styleOverride, override)
    }

    func test_subtitleEntry_styleOverride_emptyOverride_persistsAsNil() throws {
        // An override that has had every field reset (hasAnyField == false)
        // should round-trip to nil — keeping diffs/manifests bit-identical
        // to pre-feature output for projects that touched no cue style.
        let entry = SubtitleEntry(
            id: UUID(),
            relativeStart: 0,
            relativeDuration: 1.5,
            text: "no-op override",
            styleOverride: SubtitleCueStyleOverride()
        )
        let persistable = EditorRevision.PersistableSubtitle(from: entry)
        XCTAssertNil(persistable.styleOverride)
    }

    func test_subtitleEntry_hasConsistentRuns_detectsDrift() {
        let entry = SubtitleEntry(
            id: UUID(),
            relativeStart: 0,
            relativeDuration: 1.0,
            text: "Hello world",
            runs: [SubtitleRun(text: "Goodbye")]
        )
        XCTAssertFalse(entry.hasConsistentRuns)
    }

    func test_subtitleEntry_hasConsistentRuns_trueWhenRunsNil() {
        let entry = SubtitleEntry(
            id: UUID(),
            relativeStart: 0,
            relativeDuration: 1.0,
            text: "anything"
        )
        XCTAssertTrue(entry.hasConsistentRuns)
    }
}
