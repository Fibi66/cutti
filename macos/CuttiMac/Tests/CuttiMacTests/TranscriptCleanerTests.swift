import XCTest
@testable import CuttiMac

final class TranscriptCleanerTests: XCTestCase {
    // MARK: - English fillers

    func test_stripFillers_removesLeadingUm() {
        XCTAssertEqual(
            TranscriptCleaner.stripFillers("Um, please cut the first clip."),
            "please cut the first clip."
        )
    }

    func test_stripFillers_removesInlineUh() {
        XCTAssertEqual(
            TranscriptCleaner.stripFillers("Cut this, uh, section."),
            "Cut this, section."
        )
    }

    func test_stripFillers_caseInsensitive() {
        XCTAssertEqual(
            TranscriptCleaner.stripFillers("UM, Basically just trim it."),
            "just trim it."
        )
    }

    func test_stripFillers_preservesWordsContainingFillerLetters() {
        // Word-boundary guard — "umbrella" and "human" must survive.
        XCTAssertEqual(
            TranscriptCleaner.stripFillers("Human review of the umbrella clip."),
            "Human review of the umbrella clip."
        )
    }

    func test_stripFillers_removesMultiWordFillers() {
        XCTAssertEqual(
            TranscriptCleaner.stripFillers("You know, I mean this one."),
            "this one."
        )
    }

    // MARK: - Chinese fillers

    func test_stripFillers_removesChineseFiller() {
        // The trailing Chinese comma should be eaten along with the filler
        // so the cleaned output starts with the real content.
        XCTAssertEqual(
            TranscriptCleaner.stripFillers("嗯，把第一段剪掉。"),
            "把第一段剪掉。"
        )
    }

    func test_stripFillers_removesChineseMultiCharFiller() {
        XCTAssertEqual(
            TranscriptCleaner.stripFillers("那个，我想把中间部分删掉。"),
            "我想把中间部分删掉。"
        )
    }

    func test_stripFillers_collapsesSpaceBeforePunctuation() {
        // Removing the filler should also consume its trailing comma so
        // the result reads naturally — no leftover ", ,".
        XCTAssertEqual(
            TranscriptCleaner.stripFillers("Hello um, world."),
            "Hello world."
        )
    }

    // MARK: - Passthrough

    func test_stripFillers_emptyInput() {
        XCTAssertEqual(TranscriptCleaner.stripFillers(""), "")
    }

    func test_stripFillers_noFillerChangesNothing() {
        let input = "Cut segments 3 through 7."
        XCTAssertEqual(TranscriptCleaner.stripFillers(input), input)
    }
}
