import XCTest
import CuttiKit
@testable import CuttiMac

final class SubtitleExporterTests: XCTestCase {

    // MARK: - SRT

    func test_srt_emptyCues_returnsEmptyString() {
        XCTAssertEqual(SubtitleExporter.srt(from: []), "")
    }

    func test_srt_singleCue_formatsTimestampsAndIndex() {
        let cues = [
            ComposedSubtitle(id: UUID(), startSeconds: 1.5, endSeconds: 3.25, text: "Hello world")
        ]
        let expected = """
        1
        00:00:01,500 --> 00:00:03,250
        Hello world

        """
        XCTAssertEqual(SubtitleExporter.srt(from: cues), expected)
    }

    func test_srt_multipleCues_increasingIndices() {
        let cues = [
            ComposedSubtitle(id: UUID(), startSeconds: 0.0,   endSeconds: 1.2,   text: "A"),
            ComposedSubtitle(id: UUID(), startSeconds: 1.2,   endSeconds: 2.5,   text: "B"),
            ComposedSubtitle(id: UUID(), startSeconds: 3600.0, endSeconds: 3601.0, text: "C"),
        ]
        let srt = SubtitleExporter.srt(from: cues)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:01,200"))
        XCTAssertTrue(srt.contains("00:00:01,200 --> 00:00:02,500"))
        XCTAssertTrue(srt.contains("01:00:00,000 --> 01:00:01,000"))
        // Index lines present and in order.
        let indexLines = srt.split(separator: "\n").filter { Int($0) != nil }
        XCTAssertEqual(indexLines, ["1", "2", "3"])
    }

    func test_srt_skipsEmptyOrWhitespaceText() {
        let cues = [
            ComposedSubtitle(id: UUID(), startSeconds: 0, endSeconds: 1, text: "Keep"),
            ComposedSubtitle(id: UUID(), startSeconds: 1, endSeconds: 2, text: "   "),
            ComposedSubtitle(id: UUID(), startSeconds: 2, endSeconds: 3, text: ""),
            ComposedSubtitle(id: UUID(), startSeconds: 3, endSeconds: 4, text: "Also kept"),
        ]
        let srt = SubtitleExporter.srt(from: cues)
        XCTAssertTrue(srt.contains("Keep"))
        XCTAssertTrue(srt.contains("Also kept"))
        XCTAssertFalse(srt.contains("\n   \n"))
        // Renumbered after skip (1, 2 only).
        let indexLines = srt.split(separator: "\n").filter { Int($0) != nil }
        XCTAssertEqual(indexLines, ["1", "2"])
    }

    func test_srt_timestampRoundsToNearestMillisecond() {
        let cues = [
            // 0.9999 seconds should round to 001,000 rather than truncate to 000,999.
            ComposedSubtitle(id: UUID(), startSeconds: 0.9999, endSeconds: 1.4994, text: "x")
        ]
        let srt = SubtitleExporter.srt(from: cues)
        XCTAssertTrue(srt.contains("00:00:01,000 --> 00:00:01,499"), "got: \(srt)")
    }

    func test_srt_negativeTimeClampsToZero() {
        let cues = [
            ComposedSubtitle(id: UUID(), startSeconds: -0.5, endSeconds: 0.2, text: "x")
        ]
        let srt = SubtitleExporter.srt(from: cues)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:00,200"))
    }

    // MARK: - VTT

    func test_vtt_startsWithHeader() {
        let vtt = SubtitleExporter.vtt(from: [])
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
    }

    func test_vtt_usesDotSeparatorForMilliseconds() {
        let cues = [
            ComposedSubtitle(id: UUID(), startSeconds: 1.5, endSeconds: 3.25, text: "Hello")
        ]
        let vtt = SubtitleExporter.vtt(from: cues)
        XCTAssertTrue(vtt.contains("00:00:01.500 --> 00:00:03.250"))
        XCTAssertTrue(vtt.contains("Hello"))
    }

    func test_vtt_skipsEmptyCues() {
        let cues = [
            ComposedSubtitle(id: UUID(), startSeconds: 0, endSeconds: 1, text: "A"),
            ComposedSubtitle(id: UUID(), startSeconds: 1, endSeconds: 2, text: ""),
            ComposedSubtitle(id: UUID(), startSeconds: 2, endSeconds: 3, text: "B"),
        ]
        let vtt = SubtitleExporter.vtt(from: cues)
        XCTAssertTrue(vtt.contains("A"))
        XCTAssertTrue(vtt.contains("B"))
        let indexLines = vtt.split(separator: "\n").filter { Int($0) != nil }
        XCTAssertEqual(indexLines, ["1", "2"])
    }
}
