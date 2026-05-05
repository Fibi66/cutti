import XCTest
@testable import CuttiKit

final class SubtitleEntryWithTests: XCTestCase {

    private func makeEntry() -> SubtitleEntry {
        SubtitleEntry(
            id: UUID(),
            relativeStart: 1.0,
            relativeDuration: 2.0,
            text: "hello world",
            speakerID: 3,
            translations: ["zh-Hans": "你好"],
            runs: [SubtitleRun(text: "hello world", style: SubtitleRunStyle())],
            wordTimings: [WordTiming(text: "hello", startSeconds: 0, endSeconds: 0.5),
                          WordTiming(text: " world", startSeconds: 0.5, endSeconds: 1.5)],
            styleOverride: SubtitleCueStyleOverride(fontSizePoints: 70, textColor: .yellow)
        )
    }

    // MARK: - with(...) preserves fields

    func test_with_emptyArgsPreservesEverything() {
        let entry = makeEntry()
        XCTAssertEqual(entry.with(), entry)
    }

    func test_with_replacesOnlySpecifiedField_preservesStyleOverride() {
        let entry = makeEntry()
        let mutated = entry.with(text: "different text")
        XCTAssertEqual(mutated.text, "different text")
        XCTAssertEqual(mutated.styleOverride, entry.styleOverride)
        XCTAssertEqual(mutated.translations, entry.translations)
        XCTAssertEqual(mutated.runs, entry.runs)
        XCTAssertEqual(mutated.wordTimings, entry.wordTimings)
        XCTAssertEqual(mutated.speakerID, entry.speakerID)
    }

    func test_with_replacesTimes_preservesStyleOverride() {
        let entry = makeEntry()
        let resized = entry.with(relativeStart: 5, relativeDuration: 4)
        XCTAssertEqual(resized.relativeStart, 5)
        XCTAssertEqual(resized.relativeDuration, 4)
        XCTAssertEqual(resized.styleOverride, entry.styleOverride)
    }

    func test_with_replacesStyleOverride_preservesEverythingElse() {
        let entry = makeEntry()
        let newOverride = SubtitleCueStyleOverride(backgroundColor: .black)
        let updated = entry.with(styleOverride: newOverride)
        XCTAssertEqual(updated.styleOverride, newOverride)
        XCTAssertEqual(updated.text, entry.text)
        XCTAssertEqual(updated.runs, entry.runs)
    }

    // MARK: - withTextChanged

    func test_withTextChanged_clearsRunsAndTimings_preservesOverride() {
        let entry = makeEntry()
        let edited = entry.withTextChanged("brand new sentence")
        XCTAssertEqual(edited.text, "brand new sentence")
        XCTAssertNil(edited.runs, "Stale runs must be dropped")
        XCTAssertNil(edited.wordTimings, "Stale timings must be dropped")
        // Preserved:
        XCTAssertEqual(edited.styleOverride, entry.styleOverride)
        XCTAssertEqual(edited.translations, entry.translations)
        XCTAssertEqual(edited.speakerID, entry.speakerID)
        XCTAssertEqual(edited.relativeStart, entry.relativeStart)
        XCTAssertEqual(edited.relativeDuration, entry.relativeDuration)
        XCTAssertEqual(edited.id, entry.id)
    }

    // MARK: - default init keeps styleOverride nil

    func test_init_defaultsStyleOverrideToNil() {
        let entry = SubtitleEntry(
            id: UUID(),
            relativeStart: 0,
            relativeDuration: 1,
            text: "x"
        )
        XCTAssertNil(entry.styleOverride)
    }
}
