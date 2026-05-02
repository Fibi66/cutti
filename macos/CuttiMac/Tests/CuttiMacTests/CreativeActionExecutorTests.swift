import XCTest
import CuttiKit
@testable import CuttiMac

final class CreativeActionExecutorTests: XCTestCase {

    private func makePrimaryProject() -> Project {
        let primarySegment = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 10),
            text: "",
            subtitles: []
        )
        return Project(tracks: [Project.makePrimaryVideoTrack(segments: [primarySegment])])
    }

    func test_insertBRoll_appendsOverlayTrack() throws {
        let project = makePrimaryProject()
        let mediaID = UUID()

        let updated = try CreativeActionExecutor.apply(
            .insertBRoll(composedTime: 3, mediaID: mediaID, duration: 2, muteOriginal: false),
            to: project
        )

        XCTAssertEqual(updated.tracks.count, 2)
        let overlay = updated.overlayTracks.first
        XCTAssertNotNil(overlay)
        XCTAssertEqual(overlay?.kind, .overlay)
        XCTAssertEqual(overlay?.segments.count, 1)
        XCTAssertEqual(overlay?.segments.first?.placementOffset, 3)
        XCTAssertEqual(overlay?.segments.first?.durationSeconds ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(overlay?.segments.first?.sourceVideoID, mediaID)
    }

    func test_insertBRoll_clampsDurationToMediaLength() throws {
        let project = makePrimaryProject()
        let mediaID = UUID()

        let updated = try CreativeActionExecutor.apply(
            .insertBRoll(composedTime: 0, mediaID: mediaID, duration: 30, muteOriginal: false),
            to: project,
            mediaDuration: { _ in 5.0 }
        )

        XCTAssertEqual(updated.overlayTracks.first?.segments.first?.durationSeconds ?? 0, 5, accuracy: 0.001)
    }

    func test_insertBRoll_multipleCalls_createSeparateTracks() throws {
        let project = makePrimaryProject()
        let mediaA = UUID()
        let mediaB = UUID()

        let first = try CreativeActionExecutor.apply(
            .insertBRoll(composedTime: 1, mediaID: mediaA, duration: 2, muteOriginal: false),
            to: project
        )
        let second = try CreativeActionExecutor.apply(
            .insertBRoll(composedTime: 5, mediaID: mediaB, duration: 2, muteOriginal: false),
            to: first
        )

        XCTAssertEqual(second.overlayTracks.count, 2)
        XCTAssertEqual(second.overlayTracks[0].name, "V2 (B-roll)")
        XCTAssertEqual(second.overlayTracks[1].name, "V3 (B-roll)")
    }

    func test_insertBRoll_muteOriginalFlagControlsOverlayVolume() throws {
        let project = makePrimaryProject()
        let mediaID = UUID()

        let muted = try CreativeActionExecutor.apply(
            .insertBRoll(composedTime: 0, mediaID: mediaID, duration: 1, muteOriginal: true),
            to: project
        )
        let unmuted = try CreativeActionExecutor.apply(
            .insertBRoll(composedTime: 0, mediaID: mediaID, duration: 1, muteOriginal: false),
            to: project
        )

        XCTAssertEqual(muted.overlayTracks.first?.segments.first?.volumeLevel, 1.0)
        XCTAssertEqual(unmuted.overlayTracks.first?.segments.first?.volumeLevel, 0.0)
    }

    func test_apply_rejectsUnsupportedActions() {
        let project = makePrimaryProject()
        XCTAssertThrowsError(try CreativeActionExecutor.apply(
            .insertTitleCard(composedTime: 0, text: "Hi", duration: 1, style: "chapter"),
            to: project
        ))
        XCTAssertThrowsError(try CreativeActionExecutor.apply(
            .applyKenBurns(
                segmentID: UUID(),
                startRect: CreativeAction.UnitRect(x: 0, y: 0, width: 1, height: 1),
                endRect: CreativeAction.UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)
            ),
            to: project
        ))
    }
}

final class InsertBRollRequestTests: XCTestCase {

    func test_parse_happyPath() {
        let media = UUID()
        let req = InsertBRollRequest.parse(from: [
            "composed_time": 12.5,
            "media_id": media.uuidString,
            "duration": 3.0,
            "mute_original": false,
        ])
        XCTAssertEqual(req?.composedTime, 12.5)
        XCTAssertEqual(req?.mediaID, media)
        XCTAssertEqual(req?.duration, 3.0)
        XCTAssertEqual(req?.muteOriginal, false)
    }

    func test_parse_defaultsMuteOriginalToTrue() {
        let media = UUID()
        let req = InsertBRollRequest.parse(from: [
            "composed_time": 0,
            "media_id": media.uuidString,
            "duration": 1,
        ])
        XCTAssertEqual(req?.muteOriginal, true)
    }

    func test_parse_rejectsMissingMediaID() {
        XCTAssertNil(InsertBRollRequest.parse(from: [
            "composed_time": 0,
            "duration": 1,
        ]))
    }

    func test_parse_rejectsNonUUIDMediaID() {
        XCTAssertNil(InsertBRollRequest.parse(from: [
            "composed_time": 0,
            "media_id": "not-a-uuid",
            "duration": 1,
        ]))
    }

    func test_parse_acceptsIntegerNumerics() {
        let media = UUID()
        let req = InsertBRollRequest.parse(from: [
            "composed_time": 10,
            "media_id": media.uuidString,
            "duration": 2,
        ])
        XCTAssertEqual(req?.composedTime, 10)
        XCTAssertEqual(req?.duration, 2)
    }

    func test_parse_clampsNegativeComposedTime() {
        let media = UUID()
        let req = InsertBRollRequest.parse(from: [
            "composed_time": -5,
            "media_id": media.uuidString,
            "duration": 2,
        ])
        XCTAssertEqual(req?.composedTime, 0)
    }

    func test_asCreativeAction_roundTrips() {
        let media = UUID()
        let req = InsertBRollRequest(composedTime: 4, mediaID: media, duration: 1.5, muteOriginal: false)
        if case let .insertBRoll(t, id, dur, mute) = req.asCreativeAction {
            XCTAssertEqual(t, 4)
            XCTAssertEqual(id, media)
            XCTAssertEqual(dur, 1.5)
            XCTAssertEqual(mute, false)
        } else {
            XCTFail("expected insertBRoll")
        }
    }
}
