import XCTest
import CuttiKit
@testable import CuttiMac

final class CreativeActionTests: XCTestCase {

    private func makeSegment(id: UUID = UUID(), duration: Double = 3.0) -> TimelineSegment {
        TimelineSegment(
            id: id,
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: duration),
            text: "",
            subtitles: []
        )
    }

    func test_codableRoundTrip_forEveryCase() throws {
        let cases: [CreativeAction] = [
            .insertTitleCard(composedTime: 5, text: "Hi", duration: 2, style: "chapter"),
            .insertBRoll(composedTime: 10, mediaID: UUID(), duration: 3, muteOriginal: true),
            .applyKenBurns(
                segmentID: UUID(),
                startRect: .init(x: 0, y: 0, width: 1, height: 1),
                endRect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            ),
            .insertCrossfade(fromSegmentID: UUID(), toSegmentID: UUID(), duration: 0.5),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for action in cases {
            let data = try encoder.encode(action)
            let decoded = try decoder.decode(CreativeAction.self, from: data)
            XCTAssertEqual(action, decoded)
        }
    }

    func test_functionSchemas_cover_all_cases() {
        let keys = Set(CreativeAction.functionSchemas.keys)
        XCTAssertEqual(keys, ["insert_title_card", "insert_broll", "apply_ken_burns", "insert_crossfade"])
    }

    func test_crossfadeMapper_returnsPlanForAdjacentSegments() {
        let a = makeSegment(duration: 4)
        let b = makeSegment(duration: 4)
        let segments = [a, b]
        let action = CreativeAction.insertCrossfade(fromSegmentID: a.id, toSegmentID: b.id, duration: 1)
        guard let plan = CreativeActionMapper.plan(crossfade: action, in: segments) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.fromSegmentIndex, 0)
        XCTAssertEqual(plan.toSegmentIndex, 1)
        XCTAssertEqual(plan.duration, 1, accuracy: 0.001)
    }

    func test_crossfadeMapper_clampsDurationToHalfSegmentLength() {
        let a = makeSegment(duration: 1)
        let b = makeSegment(duration: 2)
        let action = CreativeAction.insertCrossfade(fromSegmentID: a.id, toSegmentID: b.id, duration: 10)
        guard let plan = CreativeActionMapper.plan(crossfade: action, in: [a, b]) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.duration, 0.5, accuracy: 0.001)
    }

    func test_crossfadeMapper_rejectsNonAdjacentPairs() {
        let a = makeSegment()
        let mid = makeSegment()
        let b = makeSegment()
        let action = CreativeAction.insertCrossfade(fromSegmentID: a.id, toSegmentID: b.id, duration: 1)
        XCTAssertNil(CreativeActionMapper.plan(crossfade: action, in: [a, mid, b]))
    }
}

final class CreativeActionCrossfadeApplyTests: XCTestCase {

    private func seg(duration: Double) -> TimelineSegment {
        TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: duration),
            text: "",
            subtitles: []
        )
    }

    func test_applyCrossfade_setsFadeOutAndFadeIn() {
        let segments = [seg(duration: 10), seg(duration: 10)]
        let plan = CreativeActionMapper.CrossfadePlan(fromSegmentIndex: 0, toSegmentIndex: 1, duration: 1.0)

        let out = CreativeActionMapper.apply(crossfade: plan, to: segments)
        XCTAssertEqual(out[0].effects.audioFadeOutDuration, 1.0, accuracy: 0.001)
        XCTAssertEqual(out[1].effects.audioFadeInDuration, 1.0, accuracy: 0.001)
    }

    func test_applyCrossfade_rejectsNonAdjacent() {
        let segments = [seg(duration: 5), seg(duration: 5), seg(duration: 5)]
        let plan = CreativeActionMapper.CrossfadePlan(fromSegmentIndex: 0, toSegmentIndex: 2, duration: 1.0)

        let out = CreativeActionMapper.apply(crossfade: plan, to: segments)
        XCTAssertEqual(out, segments)
    }

    func test_applyCrossfade_preservesLongerExistingFade() {
        var a = seg(duration: 10)
        a.effects.audioFadeOutDuration = 2.0
        let b = seg(duration: 10)
        let plan = CreativeActionMapper.CrossfadePlan(fromSegmentIndex: 0, toSegmentIndex: 1, duration: 0.5)

        let out = CreativeActionMapper.apply(crossfade: plan, to: [a, b])
        // Should keep the longer (2.0) rather than shortening to 0.5.
        XCTAssertEqual(out[0].effects.audioFadeOutDuration, 2.0, accuracy: 0.001)
        XCTAssertEqual(out[1].effects.audioFadeInDuration, 0.5, accuracy: 0.001)
    }

    func test_parseInsertCrossfade_happyPath() {
        let a = UUID(), b = UUID()
        let action = CreativeAction.parseInsertCrossfade(from: [
            "from_segment_id": a.uuidString,
            "to_segment_id": b.uuidString,
            "duration": 0.75
        ])
        if case let .insertCrossfade(from, to, dur) = action {
            XCTAssertEqual(from, a)
            XCTAssertEqual(to, b)
            XCTAssertEqual(dur, 0.75)
        } else {
            XCTFail("expected insertCrossfade")
        }
    }

    func test_parseInsertCrossfade_rejectsMalformed() {
        XCTAssertNil(CreativeAction.parseInsertCrossfade(from: [:]))
        XCTAssertNil(CreativeAction.parseInsertCrossfade(from: [
            "from_segment_id": "not-uuid",
            "to_segment_id": UUID().uuidString,
            "duration": 1
        ]))
    }
}
