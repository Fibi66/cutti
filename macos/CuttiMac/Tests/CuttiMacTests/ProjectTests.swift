import XCTest
import CuttiKit
@testable import CuttiMac

final class ProjectTests: XCTestCase {

    private func seg(start: Double = 0, end: Double = 10) -> TimelineSegment {
        TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: start, endSeconds: end),
            text: "",
            subtitles: []
        )
    }

    // MARK: - Construction

    func test_defaultProject_hasOnePrimaryVideoTrack() {
        let p = Project()
        XCTAssertEqual(p.tracks.count, 1)
        XCTAssertEqual(p.tracks[0].kind, .video)
        XCTAssertTrue(p.primaryVideoTrack.segments.isEmpty)
    }

    func test_legacyFactory_seedsPrimaryTrackWithGivenSegments() {
        let s1 = seg(start: 0, end: 5)
        let s2 = seg(start: 0, end: 3)
        let p = Project.legacy(segments: [s1, s2])
        XCTAssertEqual(p.tracks.count, 1)
        XCTAssertEqual(p.primarySegments.map(\.id), [s1.id, s2.id])
    }

    // MARK: - Primary segment shim (the compat path)

    func test_primarySegments_setter_writesBackToPrimaryTrack() {
        var p = Project()
        let s = seg(start: 0, end: 8)
        p.primarySegments = [s]
        XCTAssertEqual(p.tracks[0].segments.map(\.id), [s.id])
    }

    func test_primarySegments_setter_preservesAuxTracks() {
        let primary = Track(kind: .video, name: "V1", segments: [seg()])
        let bgm = Track(kind: .audio, name: "BGM", segments: [seg()])
        var p = Project(tracks: [primary, bgm])
        let replacement = seg(start: 100, end: 105)
        p.primarySegments = [replacement]
        // V1 replaced, BGM untouched.
        XCTAssertEqual(p.tracks[0].segments.map(\.id), [replacement.id])
        XCTAssertEqual(p.tracks[1].id, bgm.id)
        XCTAssertEqual(p.tracks[1].kind, .audio)
    }

    func test_primaryVideoTrackIndex_skipsLeadingNonVideoTracks() {
        let bgm = Track(kind: .audio, name: "BGM")
        let primary = Track(kind: .video, name: "V1")
        let overlay = Track(kind: .overlay, name: "B-roll")
        let p = Project(tracks: [bgm, primary, overlay])
        XCTAssertEqual(p.primaryVideoTrackIndex, 1)
        XCTAssertEqual(p.primaryVideoTrack.id, primary.id)
    }

    // MARK: - Convenience accessors

    func test_audioTracks_and_overlayTracks_filterByKind() {
        let v = Track(kind: .video, name: "V1")
        let a1 = Track(kind: .audio, name: "BGM")
        let a2 = Track(kind: .audio, name: "VO")
        let o = Track(kind: .overlay, name: "B-roll")
        let p = Project(tracks: [v, a1, a2, o])
        XCTAssertEqual(p.audioTracks.map(\.name), ["BGM", "VO"])
        XCTAssertEqual(p.overlayTracks.map(\.name), ["B-roll"])
    }
}
