import XCTest
@testable import CuttiKit

final class SubtitleKaraokeTests: XCTestCase {

    // MARK: - activeWordRange

    func test_activeWordRange_nilTimings_returnsNil() {
        XCTAssertNil(SubtitleKaraokeComposer.activeWordRange(
            cueText: "hello world",
            wordTimings: nil,
            entryRelativeTime: 0.5
        ))
    }

    func test_activeWordRange_emptyTimings_returnsNil() {
        XCTAssertNil(SubtitleKaraokeComposer.activeWordRange(
            cueText: "hello world",
            wordTimings: [],
            entryRelativeTime: 0.5
        ))
    }

    func test_activeWordRange_beforeFirstWord_returnsNil() {
        let timings = [
            WordTiming(text: "hello", startSeconds: 1.0, endSeconds: 1.4),
            WordTiming(text: " world", startSeconds: 1.4, endSeconds: 1.9)
        ]
        XCTAssertNil(SubtitleKaraokeComposer.activeWordRange(
            cueText: "hello world",
            wordTimings: timings,
            entryRelativeTime: 0.5
        ))
    }

    func test_activeWordRange_afterLastWord_returnsNil() {
        let timings = [
            WordTiming(text: "hello", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: " world", startSeconds: 0.4, endSeconds: 0.9)
        ]
        XCTAssertNil(SubtitleKaraokeComposer.activeWordRange(
            cueText: "hello world",
            wordTimings: timings,
            entryRelativeTime: 1.5
        ))
    }

    func test_activeWordRange_firstWord_returnsRange() {
        let timings = [
            WordTiming(text: "hello", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: " world", startSeconds: 0.4, endSeconds: 0.9)
        ]
        let range = SubtitleKaraokeComposer.activeWordRange(
            cueText: "hello world",
            wordTimings: timings,
            entryRelativeTime: 0.2
        )
        XCTAssertEqual(range, NSRange(location: 0, length: 5))
    }

    func test_activeWordRange_secondWord_leadingSpaceTrimmed() {
        let timings = [
            WordTiming(text: "hello", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: " world", startSeconds: 0.4, endSeconds: 0.9)
        ]
        let range = SubtitleKaraokeComposer.activeWordRange(
            cueText: "hello world",
            wordTimings: timings,
            entryRelativeTime: 0.5
        )
        // "world" starts at offset 6, length 5.
        XCTAssertEqual(range, NSRange(location: 6, length: 5))
    }

    func test_activeWordRange_gapBetweenWords_returnsNil() {
        let timings = [
            WordTiming(text: "hello", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: " world", startSeconds: 1.0, endSeconds: 1.5)
        ]
        XCTAssertNil(SubtitleKaraokeComposer.activeWordRange(
            cueText: "hello world",
            wordTimings: timings,
            entryRelativeTime: 0.7
        ))
    }

    func test_activeWordRange_endExclusive() {
        // Playhead exactly at endSeconds should NOT match (half-open interval).
        let timings = [
            WordTiming(text: "hi", startSeconds: 0.0, endSeconds: 0.5)
        ]
        XCTAssertNil(SubtitleKaraokeComposer.activeWordRange(
            cueText: "hi",
            wordTimings: timings,
            entryRelativeTime: 0.5
        ))
    }

    func test_activeWordRange_cjkText() {
        // Chinese cue: each timing is one character.
        let timings = [
            WordTiming(text: "你", startSeconds: 0.0, endSeconds: 0.3),
            WordTiming(text: "好", startSeconds: 0.3, endSeconds: 0.6),
            WordTiming(text: "世界", startSeconds: 0.6, endSeconds: 1.2)
        ]
        let range = SubtitleKaraokeComposer.activeWordRange(
            cueText: "你好世界",
            wordTimings: timings,
            entryRelativeTime: 0.8
        )
        // "世界" starts at utf-16 offset 2, length 2.
        XCTAssertEqual(range, NSRange(location: 2, length: 2))
    }

    func test_activeWordRange_driftRecovered_viaSearch() {
        // Cue text has an extra punctuation the timings don't know about.
        // Timings: "hello", " world"
        // Cue: "hello, world" — second timing's literal slice " world"
        // still appears after the comma, so the search fallback finds it.
        let timings = [
            WordTiming(text: "hello", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: " world", startSeconds: 0.5, endSeconds: 1.0)
        ]
        let range = SubtitleKaraokeComposer.activeWordRange(
            cueText: "hello, world",
            wordTimings: timings,
            entryRelativeTime: 0.7
        )
        XCTAssertEqual(range, NSRange(location: 7, length: 5))
    }

    func test_activeWordRange_driftUnrecoverable_skipsTiming() {
        // Second timing text is not in the cue. Should skip gracefully.
        let timings = [
            WordTiming(text: "hello", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: "zzz", startSeconds: 0.4, endSeconds: 0.9)
        ]
        XCTAssertNil(SubtitleKaraokeComposer.activeWordRange(
            cueText: "hello world",
            wordTimings: timings,
            entryRelativeTime: 0.5
        ))
    }

    // MARK: - composedRuns

    func test_composedRuns_noActiveWord_returnsBaseRuns() {
        let base: [SubtitleRun] = [SubtitleRun(text: "hello world", style: .empty)]
        let timings = [
            WordTiming(text: "hello", startSeconds: 0.0, endSeconds: 0.4)
        ]
        let out = SubtitleKaraokeComposer.composedRuns(
            cueText: "hello world",
            baseRuns: base,
            wordTimings: timings,
            entryRelativeTime: 2.0,
            highlightStyle: SubtitleRunStyle(highlightBackground: .init(red: 1, green: 1, blue: 0, alpha: 1))
        )
        XCTAssertEqual(out, base)
    }

    func test_composedRuns_nilBase_seedsAndHighlights() {
        let timings = [
            WordTiming(text: "hello", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: " world", startSeconds: 0.4, endSeconds: 0.9)
        ]
        let highlight = SubtitleRunStyle(
            highlightBackground: .init(red: 1, green: 1, blue: 0, alpha: 1)
        )
        let out = SubtitleKaraokeComposer.composedRuns(
            cueText: "hello world",
            baseRuns: nil,
            wordTimings: timings,
            entryRelativeTime: 0.2,
            highlightStyle: highlight
        )
        XCTAssertNotNil(out)
        guard let out else { return }
        XCTAssertEqual(SubtitleRunEditor.plainText(out), "hello world")
        // Expect three runs: "hello" (highlighted), " world" with no highlight
        // would collapse into one if styles match; since highlight only covers
        // the first 5 chars, we expect at least two segments with that boundary.
        var highlightedText = ""
        for run in out where run.style.highlightBackground != nil {
            highlightedText += run.text
        }
        XCTAssertEqual(highlightedText, "hello")
    }

    func test_composedRuns_preservesInvariant_plainTextMatchesCue() {
        let base: [SubtitleRun] = [
            SubtitleRun(text: "hello ", style: SubtitleRunStyle(sizeMultiplier: 1.2)),
            SubtitleRun(text: "world", style: .empty)
        ]
        let timings = [
            WordTiming(text: "hello", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: " world", startSeconds: 0.4, endSeconds: 0.9)
        ]
        let out = SubtitleKaraokeComposer.composedRuns(
            cueText: "hello world",
            baseRuns: base,
            wordTimings: timings,
            entryRelativeTime: 0.5,
            highlightStyle: SubtitleRunStyle(
                highlightBackground: .init(red: 1, green: 1, blue: 0, alpha: 1)
            )
        )
        XCTAssertNotNil(out)
        XCTAssertEqual(SubtitleRunEditor.plainText(out ?? []), "hello world")
    }

    func test_composedRuns_mergesOnAuthoredRuns() {
        // Authored run: "hello" @ size 1.5. Karaoke highlights "hello".
        // Result should keep size 1.5 AND add the highlight background.
        let base: [SubtitleRun] = [
            SubtitleRun(text: "hello", style: SubtitleRunStyle(sizeMultiplier: 1.5)),
            SubtitleRun(text: " world", style: .empty)
        ]
        let timings = [
            WordTiming(text: "hello", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: " world", startSeconds: 0.4, endSeconds: 0.9)
        ]
        let out = SubtitleKaraokeComposer.composedRuns(
            cueText: "hello world",
            baseRuns: base,
            wordTimings: timings,
            entryRelativeTime: 0.2,
            highlightStyle: SubtitleRunStyle(
                highlightBackground: .init(red: 1, green: 1, blue: 0, alpha: 1)
            )
        )
        XCTAssertNotNil(out)
        guard let out else { return }
        // Find the "hello" run.
        let helloRun = out.first(where: { $0.text == "hello" })
        XCTAssertNotNil(helloRun)
        XCTAssertEqual(helloRun?.style.sizeMultiplier, 1.5)
        XCTAssertNotNil(helloRun?.style.highlightBackground)
    }

    // MARK: - Codable

    func test_wordTiming_codableRoundTrip() throws {
        let w = WordTiming(text: "hello", startSeconds: 1.2, endSeconds: 1.5)
        let data = try JSONEncoder().encode(w)
        let decoded = try JSONDecoder().decode(WordTiming.self, from: data)
        XCTAssertEqual(w, decoded)
    }

    func test_karaokeOptions_codableRoundTrip() throws {
        let opts = SubtitleKaraokeOptions.defaultYellowPill
        let data = try JSONEncoder().encode(opts)
        let decoded = try JSONDecoder().decode(SubtitleKaraokeOptions.self, from: data)
        XCTAssertEqual(opts, decoded)
    }

    // MARK: - SubtitleStyle backward compatibility

    func test_subtitleStyle_decodesWithoutKaraokeField() throws {
        // Emit a SubtitleStyle JSON WITHOUT the karaoke field and make sure
        // old projects still decode (karaoke defaults to nil).
        let json = """
        {
          "fontName": "Helvetica",
          "fontSizePoints": 48,
          "textColor": {"red":1,"green":1,"blue":1,"alpha":1},
          "strokeColor": {"red":0,"green":0,"blue":0,"alpha":1},
          "strokeWidthFraction": 0.05,
          "backgroundColor": {"red":0,"green":0,"blue":0,"alpha":0.4},
          "backgroundPaddingHorizontal": 12,
          "backgroundPaddingVertical": 6,
          "cornerRadius": 8,
          "verticalPositionFraction": 0.85,
          "alignment": "center",
          "maxWidthFraction": 0.9,
          "shadowBlurRadius": 0,
          "shadowColor": {"red":0,"green":0,"blue":0,"alpha":0.5},
          "shadowOffsetY": 0
        }
        """.data(using: .utf8)!
        let style = try JSONDecoder().decode(SubtitleStyle.self, from: json)
        XCTAssertNil(style.karaoke)
    }
}
