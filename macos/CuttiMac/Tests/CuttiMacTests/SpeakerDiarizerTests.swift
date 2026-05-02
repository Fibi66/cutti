import XCTest
import CuttiKit
@testable import CuttiMac

final class SpeakerDiarizerTests: XCTestCase {

    private func cue(start: Double, end: Double) -> ComposedSubtitle {
        ComposedSubtitle(id: UUID(), startSeconds: start, endSeconds: end, text: "x")
    }

    func test_emptyInput_returnsEmpty() {
        XCTAssertTrue(
            SpeakerDiarizer.assignAlternatingBySilence(cues: []).isEmpty
        )
    }

    func test_singleCue_assignsSpeakerZero() {
        let result = SpeakerDiarizer.assignAlternatingBySilence(
            cues: [cue(start: 0, end: 3)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerID, 0)
    }

    func test_consecutiveCuesWithoutPauseStayOnSameSpeaker() {
        // 3 back-to-back cues, no gaps. Same speaker the whole time.
        let result = SpeakerDiarizer.assignAlternatingBySilence(
            cues: [
                cue(start: 0, end: 2),
                cue(start: 2.1, end: 4),
                cue(start: 4.0, end: 5),
            ],
            pauseThreshold: 1.5
        )
        XCTAssertEqual(result.map { $0.speakerID! }, [0, 0, 0])
    }

    func test_pauseLongerThanThresholdFlipsSpeaker() {
        let result = SpeakerDiarizer.assignAlternatingBySilence(
            cues: [
                cue(start: 0, end: 2),
                cue(start: 4, end: 6),     // 2s gap > 1.5s → flip
                cue(start: 6.2, end: 7),   // 0.2s gap → stay
                cue(start: 10, end: 12),   // 3s gap > 1.5s → flip back
            ],
            pauseThreshold: 1.5
        )
        XCTAssertEqual(result.map { $0.speakerID! }, [0, 1, 1, 0])
    }

    func test_speakerCountWrapsModuloN() {
        // With 3 speakers and a flip after every cue, IDs should round-robin.
        let cues = (0..<5).map { i in
            cue(start: Double(i) * 5, end: Double(i) * 5 + 1)
        }
        let result = SpeakerDiarizer.assignAlternatingBySilence(
            cues: cues,
            pauseThreshold: 1.0,
            speakerCount: 3
        )
        XCTAssertEqual(result.map { $0.speakerID! }, [0, 1, 2, 0, 1])
    }

    func test_registry_buildsUniqueSortedSpeakers() {
        var c1 = cue(start: 0, end: 1); c1.speakerID = 0
        var c2 = cue(start: 1, end: 2); c2.speakerID = 1
        var c3 = cue(start: 2, end: 3); c3.speakerID = 0
        let speakers = SpeakerDiarizer.registry(forCues: [c1, c2, c3])
        XCTAssertEqual(speakers.map(\.id), [0, 1])
        XCTAssertEqual(
            speakers.map(\.displayName),
            [Speaker.defaultName(for: 0), Speaker.defaultName(for: 1)]
        )
    }

    func test_registry_ignoresUnlabelledCues() {
        let c1 = cue(start: 0, end: 1) // no speakerID
        var c2 = cue(start: 1, end: 2); c2.speakerID = 0
        let speakers = SpeakerDiarizer.registry(forCues: [c1, c2])
        XCTAssertEqual(speakers.map(\.id), [0])
    }
}
