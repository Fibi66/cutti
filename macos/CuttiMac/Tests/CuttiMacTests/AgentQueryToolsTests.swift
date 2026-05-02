import XCTest
import CuttiKit
@testable import CuttiMac

final class AgentQueryToolsTests: XCTestCase {
    private let sourceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    private func makeSegment(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        speedRate: Double = 1.0,
        subtitles: [SubtitleEntry]
    ) -> TimelineSegment {
        var seg = TimelineSegment(
            id: id,
            sourceVideoID: sourceID,
            range: TimeRange(startSeconds: start, endSeconds: end),
            text: subtitles.map(\.text).joined(separator: " "),
            subtitles: subtitles
        )
        seg.speedRate = speedRate
        return seg
    }

    private func sub(_ start: Double, _ duration: Double, _ text: String) -> SubtitleEntry {
        SubtitleEntry(id: UUID(), relativeStart: start, relativeDuration: duration, text: text)
    }

    func test_walkComposedSubtitles_accumulatesOffsets() {
        let segs = [
            makeSegment(start: 0, end: 4, subtitles: [sub(0, 2, "a"), sub(2, 2, "b")]),
            makeSegment(start: 0, end: 6, subtitles: [sub(0, 3, "c"), sub(3, 3, "d")])
        ]
        let walked = AgentQuery.walkComposedSubtitles(segs)
        XCTAssertEqual(walked.count, 4)
        XCTAssertEqual(walked[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(walked[0].end, 2, accuracy: 0.001)
        XCTAssertEqual(walked[1].start, 2, accuracy: 0.001)
        // segment 2 starts at composed time 4 (segment 1 was 4s long)
        XCTAssertEqual(walked[2].start, 4, accuracy: 0.001)
        XCTAssertEqual(walked[2].end, 7, accuracy: 0.001)
        XCTAssertEqual(walked[3].start, 7, accuracy: 0.001)
        XCTAssertEqual(walked[3].end, 10, accuracy: 0.001)
    }

    func test_walkComposedSubtitles_appliesSpeedRate() {
        // 10s of source content played at 2x => 5s composed.
        let segs = [
            makeSegment(start: 0, end: 10, speedRate: 2.0,
                        subtitles: [sub(0, 4, "fast"), sub(4, 6, "rest")])
        ]
        let walked = AgentQuery.walkComposedSubtitles(segs)
        XCTAssertEqual(walked[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(walked[0].end, 2, accuracy: 0.001)   // 4s/2x = 2s
        XCTAssertEqual(walked[1].start, 2, accuracy: 0.001)
        XCTAssertEqual(walked[1].end, 5, accuracy: 0.001)   // (4+6)/2 = 5
    }

    func test_findFillerWords_singleWord_tokenized() {
        let segs = [
            makeSegment(start: 0, end: 5, subtitles: [
                sub(0, 1, "Uh, well, hello"),
                sub(1, 1, "world"),
                sub(2, 1, "嗯，是的"),
                sub(3, 2, "no fillers here")
            ])
        ]
        let matches = AgentQuery.findFillerWords(in: segs, fillerTerms: AgentDefaults.fillerWords)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].matchedTerm, "uh")
        XCTAssertEqual(matches[1].matchedTerm, "嗯")
    }

    func test_findFillerWords_multiWord_substring() {
        let segs = [
            makeSegment(start: 0, end: 3, subtitles: [
                sub(0, 1, "I mean it's not great"),
                sub(1, 1, "you know what i mean"),
                sub(2, 1, "fine")
            ])
        ]
        let matches = AgentQuery.findFillerWords(
            in: segs,
            fillerTerms: ["i mean", "you know"]
        )
        XCTAssertEqual(matches.count, 2)
    }

    func test_findFillerWords_substringNotMatchedAsSingleWord() {
        // "umbrella" contains "um" as substring but should NOT match the
        // single-word filter "um" because tokenization splits on letters.
        let segs = [
            makeSegment(start: 0, end: 1, subtitles: [
                sub(0, 1, "umbrella protects us")
            ])
        ]
        let matches = AgentQuery.findFillerWords(in: segs, fillerTerms: ["um"])
        XCTAssertTrue(matches.isEmpty)
    }

    func test_findByTranscript_caseInsensitive() {
        let segs = [
            makeSegment(start: 0, end: 4, subtitles: [
                sub(0, 2, "Talk about Pricing"),
                sub(2, 2, "next topic")
            ])
        ]
        let matches = AgentQuery.findByTranscript(query: "PRICING", in: segs)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.text, "Talk about Pricing")
    }

    func test_findByTranscript_emptyQueryReturnsNothing() {
        let segs = [
            makeSegment(start: 0, end: 2, subtitles: [sub(0, 2, "anything")])
        ]
        XCTAssertTrue(AgentQuery.findByTranscript(query: "  ", in: segs).isEmpty)
    }

    func test_summarize_includesCountsAndLongestSegments() {
        let s1 = makeSegment(start: 0, end: 2, subtitles: [sub(0, 2, "uh ok")])
        let s2 = makeSegment(start: 0, end: 10, subtitles: [sub(0, 10, "long take")])
        let s3 = makeSegment(start: 0, end: 5, subtitles: [sub(0, 5, "medium")])

        let summary = AgentQuery.summarize(
            segments: [s1, s2, s3],
            sourceNamesByID: [sourceID: "demo.mp4"]
        )
        XCTAssertEqual(summary.totalDurationSeconds, 17, accuracy: 0.001)
        XCTAssertEqual(summary.segmentCount, 3)
        XCTAssertEqual(summary.subtitleCount, 3)
        XCTAssertEqual(summary.fillerWordCount, 1)
        XCTAssertEqual(summary.sourceVideos, ["demo.mp4"])
        XCTAssertEqual(summary.longestSegments.first?.durationSeconds ?? 0, 10, accuracy: 0.001)
    }

    func test_agentToolJSON_encodesAndHandlesErrors() {
        let json = AgentToolJSON.encode(["foo": 1, "bar": 2])
        XCTAssertTrue(json.contains("\"bar\":2"))
        XCTAssertTrue(json.contains("\"foo\":1"))

        let err = AgentToolJSON.encodeError("bad arg")
        XCTAssertTrue(err.contains("bad arg"))
    }
}
