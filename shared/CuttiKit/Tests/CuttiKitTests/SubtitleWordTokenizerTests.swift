import XCTest
@testable import CuttiKit

final class SubtitleWordTokenizerTests: XCTestCase {

    func test_empty_returnsEmpty() {
        XCTAssertEqual(SubtitleWordTokenizer.tokenize("").count, 0)
    }

    func test_whitespaceOnly_returnsEmpty() {
        XCTAssertEqual(SubtitleWordTokenizer.tokenize("   \n\t  ").count, 0)
    }

    func test_englishSingleWord() {
        let tokens = SubtitleWordTokenizer.tokenize("Hello")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].text, "Hello")
        XCTAssertEqual(tokens[0].utf16Range, NSRange(location: 0, length: 5))
    }

    func test_englishMultipleWords() {
        let tokens = SubtitleWordTokenizer.tokenize("Hello world foo")
        XCTAssertEqual(tokens.map(\.text), ["Hello", "world", "foo"])
        XCTAssertEqual(tokens[0].utf16Range, NSRange(location: 0, length: 5))
        XCTAssertEqual(tokens[1].utf16Range, NSRange(location: 6, length: 5))
        XCTAssertEqual(tokens[2].utf16Range, NSRange(location: 12, length: 3))
    }

    func test_punctuationStaysWithWord() {
        let tokens = SubtitleWordTokenizer.tokenize("Hello, world!")
        XCTAssertEqual(tokens.map(\.text), ["Hello,", "world!"])
    }

    func test_chineseSplitsPerCharacter() {
        // 你好世界 → 4 tokens, one per char.
        let tokens = SubtitleWordTokenizer.tokenize("你好世界")
        XCTAssertEqual(tokens.count, 4)
        XCTAssertEqual(tokens[0].text, "你")
        XCTAssertEqual(tokens[0].utf16Range, NSRange(location: 0, length: 1))
        XCTAssertEqual(tokens[3].text, "界")
        XCTAssertEqual(tokens[3].utf16Range, NSRange(location: 3, length: 1))
    }

    func test_mixedChineseEnglish() {
        // "今天 happy 天" → [今, 天, happy, 天]
        // UTF-16: 今=0, 天=1, space=2, happy=3..7, space=8, 天=9
        let tokens = SubtitleWordTokenizer.tokenize("今天 happy 天")
        XCTAssertEqual(tokens.map(\.text), ["今", "天", "happy", "天"])
        XCTAssertEqual(tokens[0].utf16Range, NSRange(location: 0, length: 1))
        XCTAssertEqual(tokens[1].utf16Range, NSRange(location: 1, length: 1))
        XCTAssertEqual(tokens[2].utf16Range, NSRange(location: 3, length: 5))
        XCTAssertEqual(tokens[3].utf16Range, NSRange(location: 9, length: 1))
    }

    func test_leadingAndTrailingWhitespace() {
        let tokens = SubtitleWordTokenizer.tokenize("  hello  ")
        XCTAssertEqual(tokens.map(\.text), ["hello"])
        XCTAssertEqual(tokens[0].utf16Range, NSRange(location: 2, length: 5))
    }

    func test_newlinesBreakTokens() {
        let tokens = SubtitleWordTokenizer.tokenize("a\nb\tc")
        XCTAssertEqual(tokens.map(\.text), ["a", "b", "c"])
    }

    func test_numbersAndDotsStayInWord() {
        let tokens = SubtitleWordTokenizer.tokenize("$3.50 is 1.5x")
        XCTAssertEqual(tokens.map(\.text), ["$3.50", "is", "1.5x"])
    }

    // MARK: - Range merging

    func test_mergeRanges_empty() {
        XCTAssertEqual(SubtitleWordTokenizer.mergeRanges([]).count, 0)
    }

    func test_mergeRanges_adjacentWordTokens() {
        // "Hello world" — "Hello"=0..5, "world"=6..11. Not adjacent (space
        // between). Stays as two ranges.
        let r1 = NSRange(location: 0, length: 5)
        let r2 = NSRange(location: 6, length: 5)
        XCTAssertEqual(SubtitleWordTokenizer.mergeRanges([r1, r2]), [r1, r2])
    }

    func test_mergeRanges_trulyAdjacent() {
        // CJK chars are adjacent: 0..1, 1..2, 2..3 should merge to 0..3.
        let ranges = [
            NSRange(location: 0, length: 1),
            NSRange(location: 1, length: 1),
            NSRange(location: 2, length: 1),
        ]
        let merged = SubtitleWordTokenizer.mergeRanges(ranges)
        XCTAssertEqual(merged, [NSRange(location: 0, length: 3)])
    }

    func test_mergeRanges_overlapping() {
        let ranges = [
            NSRange(location: 0, length: 5),
            NSRange(location: 3, length: 5),
        ]
        XCTAssertEqual(
            SubtitleWordTokenizer.mergeRanges(ranges),
            [NSRange(location: 0, length: 8)]
        )
    }

    func test_mergeRanges_sortsBeforeMerging() {
        let r1 = NSRange(location: 5, length: 3)  // 5..8
        let r2 = NSRange(location: 0, length: 4)  // 0..4
        let r3 = NSRange(location: 4, length: 1)  // 4..5 (bridges r1 and r2)
        let merged = SubtitleWordTokenizer.mergeRanges([r1, r2, r3])
        XCTAssertEqual(merged, [NSRange(location: 0, length: 8)])
    }
}
