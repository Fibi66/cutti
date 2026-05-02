import XCTest
import CuttiKit
@testable import CuttiMac

final class EditorRevisionTests: XCTestCase {
    func test_persistableSegment_roundTrip_preservesAlternativeTakes() throws {
        let srcID = UUID()
        let takeID = UUID()
        let alt = AlternativeTake(
            id: takeID,
            sourceVideoID: srcID,
            startSeconds: 10.0,
            endSeconds: 14.0,
            text: "alternate take",
            reason: "重启重复"
        )
        var seg = TimelineSegment(
            id: UUID(),
            sourceVideoID: srcID,
            range: TimeRange(startSeconds: 0, endSeconds: 5),
            text: "primary",
            subtitles: []
        )
        seg.alternatives = [alt]

        let persistable = EditorRevision.PersistableSegment(from: seg)
        let data = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(EditorRevision.PersistableSegment.self, from: data)
        let restored = decoded.toTimelineSegment()

        XCTAssertEqual(restored.alternatives.count, 1)
        let restoredAlt = try XCTUnwrap(restored.alternatives.first)
        XCTAssertEqual(restoredAlt.id, takeID)
        XCTAssertEqual(restoredAlt.sourceVideoID, srcID)
        XCTAssertEqual(restoredAlt.startSeconds, 10.0, accuracy: 1e-9)
        XCTAssertEqual(restoredAlt.endSeconds, 14.0, accuracy: 1e-9)
        XCTAssertEqual(restoredAlt.text, "alternate take")
        XCTAssertEqual(restoredAlt.reason, "重启重复")
    }

    func test_persistableSegment_decode_missingAlternativesFieldDefaultsEmpty() throws {
        // Legacy revisions (pre-feature) never wrote `alternatives`.
        // Ensure they decode with an empty array instead of crashing.
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "sourceVideoID": "\(UUID().uuidString)",
          "startSeconds": 0,
          "endSeconds": 1,
          "text": "t",
          "volumeLevel": 1.0,
          "speedRate": 1.0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorRevision.PersistableSegment.self, from: legacyJSON)
        XCTAssertEqual(decoded.toTimelineSegment().alternatives, [])
    }

    func test_persistableSegment_roundTrip_preservesSubtitlesAndSpeakerID() {
        let subID = UUID()
        let sub = SubtitleEntry(
            id: subID,
            relativeStart: 1.0,
            relativeDuration: 2.5,
            text: "Hello world",
            speakerID: 1
        )
        let segID = UUID()
        let srcID = UUID()
        var seg = TimelineSegment(
            id: segID,
            sourceVideoID: srcID,
            range: TimeRange(startSeconds: 0, endSeconds: 10),
            text: "Segment",
            subtitles: [sub]
        )
        seg.volumeLevel = 0.7
        seg.speedRate = 1.25

        let persistable = EditorRevision.PersistableSegment(from: seg)
        let restored = persistable.toTimelineSegment()

        XCTAssertEqual(restored.id, segID)
        XCTAssertEqual(restored.volumeLevel, 0.7, accuracy: 1e-9)
        XCTAssertEqual(restored.speedRate, 1.25, accuracy: 1e-9)
        XCTAssertEqual(restored.subtitles.count, 1)
        XCTAssertEqual(restored.subtitles.first?.id, subID)
        XCTAssertEqual(restored.subtitles.first?.speakerID, 1)
        XCTAssertEqual(restored.subtitles.first?.text, "Hello world")
    }

    func test_revision_decodes_legacyWithoutTracks() throws {
        // Simulate a revision written before multitrack (no `tracks` key):
        // encode a revision with tracks=nil and verify decode round-trip.
        let rev = EditorRevision(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1000),
            label: "legacy",
            segments: [],
            selectedSegmentID: nil,
            playheadSeconds: 0,
            trigger: .userEdit(description: ""),
            tracks: nil
        )
        let data = try JSONEncoder().encode(rev)
        // Sanity: no "tracks" key should have been written.
        let raw = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("\"tracks\""))

        let decoded = try JSONDecoder().decode(EditorRevision.self, from: data)
        XCTAssertNil(decoded.tracks)
        XCTAssertEqual(decoded.label, "legacy")
    }

    func test_revision_roundTrip_withTracks_preservesAuxTracks() throws {
        let auxSeg = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 30),
            text: "bgm",
            subtitles: []
        )
        let audioTrack = Track(
            id: UUID(),
            kind: .audio,
            name: "BGM",
            isMuted: false,
            isSolo: false,
            segments: [auxSeg]
        )
        let videoTrack = Project.makePrimaryVideoTrack(segments: [])
        let project = Project(tracks: [videoTrack, audioTrack])

        let rev = EditorRevision(
            id: UUID(),
            timestamp: Date(),
            label: "after-bgm",
            segments: [],
            selectedSegmentID: nil,
            playheadSeconds: 0,
            trigger: .userEdit(description: "add bgm"),
            tracks: project.tracks.map { EditorRevision.PersistableTrack(from: $0) }
        )

        let data = try JSONEncoder().encode(rev)
        let decoded = try JSONDecoder().decode(EditorRevision.self, from: data)
        XCTAssertEqual(decoded.tracks?.count, 2)
        XCTAssertEqual(decoded.tracks?[1].kind, "audio")
        XCTAssertEqual(decoded.tracks?[1].name, "BGM")
        XCTAssertEqual(decoded.tracks?[1].segments.count, 1)
    }

    // MARK: - PiP layout persistence

    func test_persistableSegment_roundTrip_preservesPiPLayout() throws {
        var seg = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 5),
            text: "presenter",
            subtitles: []
        )
        seg.pipLayout = PiPLayout(
            shape: .circle,
            corner: .topRight,
            sizeFraction: 0.28,
            insetFraction: 0.04,
            borderWidthPx: 3,
            borderColorHex: "#FFFFFFFF",
            shadowEnabled: true
        )

        let persistable = EditorRevision.PersistableSegment(from: seg)
        let data = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(EditorRevision.PersistableSegment.self, from: data)
        let restored = decoded.toTimelineSegment()

        let layout = try XCTUnwrap(restored.pipLayout)
        XCTAssertEqual(layout.shape, .circle)
        XCTAssertEqual(layout.corner, .topRight)
        XCTAssertEqual(layout.sizeFraction, 0.28, accuracy: 1e-9)
        XCTAssertEqual(layout.insetFraction, 0.04, accuracy: 1e-9)
        XCTAssertEqual(layout.borderWidthPx, 3, accuracy: 1e-9)
        XCTAssertEqual(layout.borderColorHex, "#FFFFFFFF")
        XCTAssertTrue(layout.shadowEnabled)
    }

    func test_persistableSegment_decode_missingPiPLayoutDefaultsNil() throws {
        // Pre-feature revisions never wrote pipLayout. Ensure legacy
        // segments decode with pipLayout == nil instead of crashing.
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "sourceVideoID": "\(UUID().uuidString)",
          "startSeconds": 0,
          "endSeconds": 1,
          "text": "t",
          "volumeLevel": 1.0,
          "speedRate": 1.0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorRevision.PersistableSegment.self, from: legacyJSON)
        XCTAssertNil(decoded.toTimelineSegment().pipLayout)
    }

    func test_pipLayout_normalized_clampsOutOfRangeValues() {
        let oversized = PiPLayout(
            shape: .roundedSquare,
            corner: .bottomRight,
            sizeFraction: 2.0,     // above max
            insetFraction: -0.5,   // below min
            borderWidthPx: -4,     // below min
            borderColorHex: nil,
            shadowEnabled: false
        ).normalized()

        XCTAssertEqual(oversized.sizeFraction, PiPLayout.maxSizeFraction, accuracy: 1e-9)
        XCTAssertEqual(oversized.insetFraction, 0, accuracy: 1e-9)
        XCTAssertEqual(oversized.borderWidthPx, 0, accuracy: 1e-9)

        let undersized = PiPLayout(
            shape: .circle,
            corner: .topLeft,
            sizeFraction: 0.001,
            insetFraction: 0.02,
            borderWidthPx: 1,
            borderColorHex: nil,
            shadowEnabled: false
        ).normalized()

        XCTAssertEqual(undersized.sizeFraction, PiPLayout.minSizeFraction, accuracy: 1e-9)
        XCTAssertEqual(undersized.insetFraction, 0.02, accuracy: 1e-9)
        XCTAssertEqual(undersized.borderWidthPx, 1, accuracy: 1e-9)
    }

    func test_persistableSegment_toTimelineSegment_normalizesStoredPiPLayout() throws {
        // If a revision on disk somehow contains an out-of-range layout
        // (older build, hand-edited JSON), the restored TimelineSegment
        // must still present a clamped layout so the renderer is safe.
        var seg = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 5),
            text: "",
            subtitles: []
        )
        seg.pipLayout = PiPLayout(
            shape: .square,
            corner: .bottomLeft,
            sizeFraction: 10.0,
            insetFraction: 10.0,
            borderWidthPx: -1,
            borderColorHex: nil,
            shadowEnabled: false
        )

        let persistable = EditorRevision.PersistableSegment(from: seg)
        let data = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(EditorRevision.PersistableSegment.self, from: data)
        let restored = decoded.toTimelineSegment()

        let layout = try XCTUnwrap(restored.pipLayout)
        XCTAssertLessThanOrEqual(layout.sizeFraction, PiPLayout.maxSizeFraction)
        XCTAssertLessThanOrEqual(layout.insetFraction, PiPLayout.maxInsetFraction)
        XCTAssertGreaterThanOrEqual(layout.borderWidthPx, 0)
    }
}
