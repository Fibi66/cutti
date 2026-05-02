import XCTest
import Foundation
@testable import CuttiMac
@testable import CuttiKit

final class AgentEmphasizeWordsToolTests: XCTestCase {

    // MARK: Parsing

    func test_parse_requires_cueID_or_atTime() {
        let args: [String: Any] = [
            "words": ["hi"],
            "style": ["weight": "bold"]
        ]
        XCTAssertNil(EmphasizeWordsRequest.parse(from: args))
    }

    func test_parse_requires_targeting_when_not_clearing() {
        let args: [String: Any] = [
            "cue_id": UUID().uuidString,
            "style": ["weight": "bold"]
        ]
        XCTAssertNil(EmphasizeWordsRequest.parse(from: args))
    }

    func test_parse_requires_nonempty_style_when_not_clearing() {
        let args: [String: Any] = [
            "cue_id": UUID().uuidString,
            "words": ["hi"],
            "style": [:]
        ]
        XCTAssertNil(EmphasizeWordsRequest.parse(from: args))
    }

    func test_parse_clear_all_bypasses_style_check() {
        let cueID = UUID()
        let args: [String: Any] = [
            "cue_id": cueID.uuidString,
            "clear_all": true
        ]
        let req = EmphasizeWordsRequest.parse(from: args)
        XCTAssertNotNil(req)
        XCTAssertTrue(req?.clearAll ?? false)
        XCTAssertEqual(req?.cueID, cueID)
    }

    func test_parse_words_with_style_bold() {
        let args: [String: Any] = [
            "cue_id": UUID().uuidString,
            "words": ["hello", "world"],
            "style": ["weight": "bold", "size_multiplier": 1.5]
        ]
        let req = EmphasizeWordsRequest.parse(from: args)
        XCTAssertEqual(req?.words, ["hello", "world"])
        XCTAssertEqual(req?.style.weight, .bold)
        XCTAssertEqual(req?.style.sizeMultiplier, 1.5)
    }

    func test_parse_utf16_ranges() {
        let args: [String: Any] = [
            "cue_id": UUID().uuidString,
            "utf16_ranges": [[0, 5], [7, 12]],
            "style": ["weight": "bold"]
        ]
        let req = EmphasizeWordsRequest.parse(from: args)
        XCTAssertEqual(req?.utf16Ranges.count, 2)
        XCTAssertEqual(req?.utf16Ranges.first?.location, 0)
        XCTAssertEqual(req?.utf16Ranges.first?.length, 5)
    }

    func test_parse_utf16_ranges_rejects_inverted() {
        let args: [String: Any] = [
            "cue_id": UUID().uuidString,
            "utf16_ranges": [[5, 5], [10, 3]],
            "style": ["weight": "bold"]
        ]
        let req = EmphasizeWordsRequest.parse(from: args)
        // Both are invalid (end<=start) so ranges stays empty; with no
        // words either, parse returns nil.
        XCTAssertNil(req)
    }

    func test_parse_size_multiplier_clamped() {
        let argsHigh: [String: Any] = [
            "cue_id": UUID().uuidString,
            "words": ["hi"],
            "style": ["size_multiplier": 99.0]
        ]
        XCTAssertEqual(EmphasizeWordsRequest.parse(from: argsHigh)?.style.sizeMultiplier, 4.0)

        let argsLow: [String: Any] = [
            "cue_id": UUID().uuidString,
            "words": ["hi"],
            "style": ["size_multiplier": 0.01]
        ]
        XCTAssertEqual(EmphasizeWordsRequest.parse(from: argsLow)?.style.sizeMultiplier, 0.25)
    }

    func test_parse_weight_normalizes_case() {
        let args: [String: Any] = [
            "cue_id": UUID().uuidString,
            "words": ["hi"],
            "style": ["weight": "BOLD"]
        ]
        XCTAssertEqual(EmphasizeWordsRequest.parse(from: args)?.style.weight, .bold)
    }

    func test_parse_invalid_weight_ignored() {
        let args: [String: Any] = [
            "cue_id": UUID().uuidString,
            "words": ["hi"],
            "style": ["weight": "wat"]
        ]
        // weight ignored but style still has nothing else → empty
        XCTAssertNil(EmphasizeWordsRequest.parse(from: args))
    }

    // MARK: Hex color parsing

    func test_parseHexColor_rgb_with_hash() {
        let c = EmphasizeWordsRequest.parseHexColor("#FF0000")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.red ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(c?.green ?? 0, 0.0, accuracy: 0.001)
        XCTAssertEqual(c?.blue ?? 0, 0.0, accuracy: 0.001)
        XCTAssertEqual(c?.alpha ?? 0, 1.0, accuracy: 0.001)
    }

    func test_parseHexColor_rgba() {
        let c = EmphasizeWordsRequest.parseHexColor("00FF0080")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.green ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(c?.alpha ?? 0, 128.0 / 255.0, accuracy: 0.001)
    }

    func test_parseHexColor_invalid() {
        XCTAssertNil(EmphasizeWordsRequest.parseHexColor("nope"))
        XCTAssertNil(EmphasizeWordsRequest.parseHexColor("#XYZXYZ"))
        XCTAssertNil(EmphasizeWordsRequest.parseHexColor("#FFF"))
    }

    // MARK: Matcher

    func test_matcher_finds_all_occurrences() {
        let result = EmphasizeWordsMatcher.resolve(
            words: ["okay"],
            inCueText: "okay okay so we're okay"
        )
        XCTAssertEqual(result.ranges.count, 3)
        XCTAssertEqual(result.wordsMatched, ["okay"])
        XCTAssertTrue(result.wordsNotFound.isEmpty)
    }

    func test_matcher_chinese_single_char() {
        let result = EmphasizeWordsMatcher.resolve(
            words: ["我"],
            inCueText: "我今天去找我朋友"
        )
        XCTAssertEqual(result.ranges.count, 2)
        XCTAssertEqual(result.ranges[0].location, 0)
        XCTAssertEqual(result.ranges[1].location, 5)
    }

    func test_matcher_reports_not_found() {
        let result = EmphasizeWordsMatcher.resolve(
            words: ["hello", "nope", "world"],
            inCueText: "hello world"
        )
        XCTAssertEqual(result.wordsMatched, ["hello", "world"])
        XCTAssertEqual(result.wordsNotFound, ["nope"])
    }

    func test_matcher_dedupes_word_list() {
        let result = EmphasizeWordsMatcher.resolve(
            words: ["a", "a", "a"],
            inCueText: "a b a"
        )
        XCTAssertEqual(result.ranges.count, 2)
        XCTAssertEqual(result.wordsMatched, ["a"])
    }

    func test_matcher_drops_contained_ranges() {
        // "important" and "import" — "important" encompasses "import"
        let result = EmphasizeWordsMatcher.resolve(
            words: ["important", "import"],
            inCueText: "This is important"
        )
        // Both words match but "import" is fully inside "important".
        // Compact step drops the shorter inside the longer.
        XCTAssertEqual(result.ranges.count, 1)
        XCTAssertEqual(result.ranges[0].length, 9) // "important"
    }

    func test_matcher_empty_cue() {
        let result = EmphasizeWordsMatcher.resolve(
            words: ["x"],
            inCueText: ""
        )
        XCTAssertTrue(result.ranges.isEmpty)
        XCTAssertEqual(result.wordsNotFound, ["x"])
    }

    func test_matcher_phrase_match() {
        let result = EmphasizeWordsMatcher.resolve(
            words: ["really cool"],
            inCueText: "that was really cool today"
        )
        XCTAssertEqual(result.ranges.count, 1)
        XCTAssertEqual(result.ranges[0].length, 11)
    }
}
