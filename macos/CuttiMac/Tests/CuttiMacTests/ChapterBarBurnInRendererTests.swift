import XCTest
import CuttiKit
@testable import CuttiMac

final class ChapterBarBurnInRendererTests: XCTestCase {

    private func makeChapters() -> [VideoChapter] {
        [
            VideoChapter(startSeconds: 0, endSeconds: 10, title: "Intro"),
            VideoChapter(startSeconds: 10, endSeconds: 25, title: "Body"),
            VideoChapter(startSeconds: 25, endSeconds: 40, title: "Outro"),
        ]
    }

    func test_chapterAtTime_picksFirstChapterBeforeBoundary() {
        let renderer = ChapterBarBurnInRenderer(
            chapters: makeChapters(),
            totalSeconds: 40,
            renderSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(renderer.chapter(at: 0)?.index, 0)
        XCTAssertEqual(renderer.chapter(at: 9.99)?.index, 0)
    }

    func test_chapterAtTime_advancesAtBoundary() {
        let renderer = ChapterBarBurnInRenderer(
            chapters: makeChapters(),
            totalSeconds: 40,
            renderSize: CGSize(width: 1920, height: 1080)
        )
        // Boundary belongs to the next chapter (start-inclusive).
        XCTAssertEqual(renderer.chapter(at: 10)?.index, 1)
        XCTAssertEqual(renderer.chapter(at: 24.99)?.index, 1)
        XCTAssertEqual(renderer.chapter(at: 25)?.index, 2)
    }

    func test_chapterAtTime_clampsBeyondEnd() {
        let renderer = ChapterBarBurnInRenderer(
            chapters: makeChapters(),
            totalSeconds: 40,
            renderSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(renderer.chapter(at: 100)?.index, 2)
    }

    func test_overlay_producesImageWhenChaptersPresent() {
        let renderer = ChapterBarBurnInRenderer(
            chapters: makeChapters(),
            totalSeconds: 40,
            renderSize: CGSize(width: 1280, height: 720)
        )
        XCTAssertNotNil(renderer.overlay(at: 5))
        XCTAssertNotNil(renderer.overlay(at: 30))
    }

    func test_overlay_nilForEmptyChapters() {
        let renderer = ChapterBarBurnInRenderer(
            chapters: [],
            totalSeconds: 40,
            renderSize: CGSize(width: 1280, height: 720)
        )
        XCTAssertNil(renderer.overlay(at: 5))
    }

    func test_overlay_nilForZeroTotal() {
        let renderer = ChapterBarBurnInRenderer(
            chapters: makeChapters(),
            totalSeconds: 0,
            renderSize: CGSize(width: 1280, height: 720)
        )
        XCTAssertNil(renderer.overlay(at: 5))
    }

    func test_overlay_rendersWithTopAnchorStyle() {
        var style = ChapterBarStyle.default
        style.anchor = .top
        style.backgroundColor = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
        style.backgroundOpacity = 0.5
        style.fontColor = RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)
        style.fontSize = 40
        let renderer = ChapterBarBurnInRenderer(
            chapters: makeChapters(),
            totalSeconds: 40,
            renderSize: CGSize(width: 1280, height: 720),
            style: style
        )
        XCTAssertNotNil(renderer.overlay(at: 12))
    }

    func test_chapterBarStyle_codableRoundTrip() throws {
        let original = ChapterBarStyle(
            anchor: .top,
            backgroundColor: RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9),
            backgroundOpacity: 0.42,
            fontColor: RGBAColor(red: 1, green: 0.5, blue: 0, alpha: 1),
            fontSize: 34
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChapterBarStyle.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_snapshot_decodesOldProjectWithoutStyleField() throws {
        // Pre-style snapshot: only chapters, no chapterBarStyle key.
        let json = """
        {"semanticTags":[],"issues":[],"suggestions":[],"markers":[],
         "chapters":[{"id":"C1E1F5EA-0000-0000-0000-000000000001","startSeconds":0,"endSeconds":10,"title":"Intro"}]}
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(AICopilotSnapshot.self, from: json)
        XCTAssertEqual(snapshot.chapters?.count, 1)
        XCTAssertNil(snapshot.chapterBarStyle)
    }
}

final class LLMEditorServiceChapterTests: XCTestCase {

    func test_normalizeChapters_clampsAndCovers() {
        let raw: [VideoChapter] = [
            VideoChapter(startSeconds: -5, endSeconds: 12, title: "A"),
            VideoChapter(startSeconds: 12, endSeconds: 30, title: "B"),
            VideoChapter(startSeconds: 30, endSeconds: 90, title: "C"),  // out-of-range end
        ]
        let normalized = LLMEditorService.normalizeChapters(raw, totalDuration: 50)
        XCTAssertEqual(normalized.count, 3)
        XCTAssertEqual(normalized.first?.startSeconds, 0)
        XCTAssertEqual(normalized.last?.endSeconds, 50)
        // Contiguous: each chapter's start equals previous end.
        for i in 1..<normalized.count {
            XCTAssertEqual(normalized[i].startSeconds, normalized[i - 1].endSeconds, accuracy: 0.0001)
        }
    }

    func test_normalizeChapters_fixesOverlap() {
        let raw: [VideoChapter] = [
            VideoChapter(startSeconds: 0, endSeconds: 20, title: "A"),
            VideoChapter(startSeconds: 10, endSeconds: 30, title: "B"),  // overlaps A
        ]
        let normalized = LLMEditorService.normalizeChapters(raw, totalDuration: 30)
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].endSeconds, 20)
        XCTAssertEqual(normalized[1].startSeconds, 20)
        XCTAssertEqual(normalized[1].endSeconds, 30)
    }

    func test_normalizeChapters_dropsTooShortByMerging() {
        let raw: [VideoChapter] = [
            VideoChapter(startSeconds: 0, endSeconds: 10, title: "A"),
            VideoChapter(startSeconds: 10, endSeconds: 10.4, title: "Tiny"),
            VideoChapter(startSeconds: 10.4, endSeconds: 30, title: "B"),
        ]
        let normalized = LLMEditorService.normalizeChapters(raw, totalDuration: 30)
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].endSeconds, 10.4, accuracy: 0.0001)
        XCTAssertEqual(normalized[1].startSeconds, 10.4, accuracy: 0.0001)
    }

    func test_normalizeChapters_emptyInputProducesSingleCoveringChapter() {
        let normalized = LLMEditorService.normalizeChapters([], totalDuration: 60)
        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].startSeconds, 0)
        XCTAssertEqual(normalized[0].endSeconds, 60)
    }

    func test_normalizeChapters_zeroTotalReturnsEmpty() {
        let normalized = LLMEditorService.normalizeChapters([
            VideoChapter(startSeconds: 0, endSeconds: 10, title: "A")
        ], totalDuration: 0)
        XCTAssertTrue(normalized.isEmpty)
    }
}

final class ChapterBarOverlayTimeFormatTests: XCTestCase {

    func test_formatTime_padsToMinSecMillis() {
        XCTAssertEqual(ChapterBarOverlay.formatTime(0), "00:00.000")
        XCTAssertEqual(ChapterBarOverlay.formatTime(5.25), "00:05.250")
        XCTAssertEqual(ChapterBarOverlay.formatTime(75.123), "01:15.123")
        XCTAssertEqual(ChapterBarOverlay.formatTime(3725.999), "62:05.999")
    }

    func test_parseTime_acceptsMultipleFormats() {
        XCTAssertEqual(ChapterBarOverlay.parseTime("01:15.250") ?? 0, 75.25, accuracy: 0.0001)
        XCTAssertEqual(ChapterBarOverlay.parseTime("01:15") ?? 0, 75.0, accuracy: 0.0001)
        XCTAssertEqual(ChapterBarOverlay.parseTime("15") ?? 0, 15.0, accuracy: 0.0001)
        XCTAssertEqual(ChapterBarOverlay.parseTime("5.5") ?? 0, 5.5, accuracy: 0.0001)
    }

    func test_parseTime_rejectsGarbage() {
        XCTAssertNil(ChapterBarOverlay.parseTime("abc"))
        XCTAssertNil(ChapterBarOverlay.parseTime("1:2:3"))
    }

    func test_parseTime_roundTripWithFormatTime() {
        for seconds in [0.0, 12.5, 75.123, 3725.999] {
            let s = ChapterBarOverlay.formatTime(seconds)
            let parsed = ChapterBarOverlay.parseTime(s)
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed ?? -1, seconds, accuracy: 0.001)
        }
    }
}
