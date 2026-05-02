import AVFoundation
import XCTest
import CuttiKit
@testable import CuttiMac

final class CompositionBuilderTests: XCTestCase {
    func test_build_keepsSourceAssetAliveWhileSplicingSegments() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/sample-h264-640x360.mp4")

        let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let segments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: sourceID,
                range: TimeRange(startSeconds: 0.0, endSeconds: 0.35),
                text: "Intro",
                subtitles: []
            ),
            TimelineSegment(
                id: UUID(),
                sourceVideoID: sourceID,
                range: TimeRange(startSeconds: 0.35, endSeconds: 0.7),
                text: "Middle",
                subtitles: []
            ),
            TimelineSegment(
                id: UUID(),
                sourceVideoID: sourceID,
                range: TimeRange(startSeconds: 0.7, endSeconds: 1.0),
                text: "End",
                subtitles: []
            )
        ]

        let result = try await CompositionBuilder.build(
            sourceLookup: { _ in fixture },
            segments: segments
        )

        XCTAssertGreaterThan(result.composition.duration.seconds, 0.9)
    }

    func test_build_scalesDurationForSpeedAdjustedSegment() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/sample-h264-640x360.mp4")

        let sourceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var fastSegment = TimelineSegment(
            id: UUID(),
            sourceVideoID: sourceID,
            range: TimeRange(startSeconds: 0.0, endSeconds: 1.0),
            text: "Fast",
            subtitles: []
        )
        fastSegment.speedRate = 2.0

        let result = try await CompositionBuilder.build(
            sourceLookup: { _ in fixture },
            segments: [fastSegment]
        )

        XCTAssertEqual(result.composition.duration.seconds, 0.5, accuracy: 0.08)
    }

    func test_quantizedSeconds_matchesCompositionTimebase() {
        let rawDurations: [Double] = [
            0.920003051757817,
            2.3999987792968795,
            3.7399951171875045,
            3.759999389648442
        ]

        for duration in rawDurations {
            XCTAssertEqual(
                quantizedSeconds(duration),
                CMTime(seconds: duration, preferredTimescale: 600).seconds,
                accuracy: 0.000_000_1,
                "timeline duration quantization drifted from CompositionBuilder for \(duration)"
            )
        }
    }

    // MARK: - Image overlay instruction wiring

    func test_buildPiPInstructions_imagePlacementBecomesImageEntry() {
        let imageURL = URL(fileURLWithPath: "/tmp/fake-image.png")
        let placements: [CompositionBuilder.PiPInstructionPlacement] = [
            .init(
                source: .image(url: imageURL),
                composedStart: 1.0,
                composedEnd: 3.0,
                pipLayout: nil,
                freeTransform: nil
            )
        ]
        let instructions = CompositionBuilder.buildPiPInstructions(
            primaryTrackID: 100,
            overlayPlacements: placements,
            totalDuration: 5.0,
            composedInfos: [],
            subtitleRenderer: nil,
            chapterRenderer: nil
        )
        // Interval covering [1,3] must contain exactly one overlay entry
        // tagged as .image — not .track — so the compositor reads the
        // URL cache instead of trying to fetch a non-existent source
        // frame.
        let imageIntervals = instructions.filter { inst in
            inst.overlays.contains { entry in
                if case .image = entry.source { return true } else { return false }
            }
        }
        XCTAssertFalse(imageIntervals.isEmpty, "expected at least one instruction with an .image overlay")
        for inst in imageIntervals {
            // requiredSourceTrackIDs should include the primary (100)
            // but NOT any synthetic image ID. Only the primary is a
            // real AV track in this scenario.
            let required = inst.requiredSourceTrackIDs?.map { ($0 as? NSNumber)?.int32Value ?? -1 } ?? []
            XCTAssertEqual(required, [100], "image overlays must not appear in requiredSourceTrackIDs")
        }
    }

    func test_buildPiPInstructions_mixesTrackAndImageOverlays() {
        let imageURL = URL(fileURLWithPath: "/tmp/fake.png")
        let placements: [CompositionBuilder.PiPInstructionPlacement] = [
            .init(source: .track(201), composedStart: 0.0, composedEnd: 2.0, pipLayout: nil, freeTransform: nil),
            .init(source: .image(url: imageURL), composedStart: 1.0, composedEnd: 3.0, pipLayout: nil, freeTransform: nil)
        ]
        let instructions = CompositionBuilder.buildPiPInstructions(
            primaryTrackID: 100,
            overlayPlacements: placements,
            totalDuration: 4.0,
            composedInfos: [],
            subtitleRenderer: nil,
            chapterRenderer: nil
        )
        // Boundary points: 0, 1, 2, 3, 4 → 4 instructions.
        // [1,2] interval should contain BOTH entries.
        let overlapping = instructions.first { inst in
            inst.timeRange.start.seconds > 0.99 && inst.timeRange.start.seconds < 1.01
        }
        XCTAssertNotNil(overlapping)
        XCTAssertEqual(overlapping?.overlays.count, 2)
        // Required source IDs for overlapping interval = primary (100)
        // + track overlay (201). The image entry contributes nothing.
        let required = Set(overlapping?.requiredSourceTrackIDs?.compactMap { ($0 as? NSNumber)?.int32Value } ?? [])
        XCTAssertEqual(required, [100, 201])
    }

    // MARK: - FreeTransform propagation

    /// FreeTransform set on a placement must survive the conversion to
    /// OverlayEntry so the compositor can apply it. Regression guard
    /// for the wiring between `CompositionBuilder.PiPInstructionPlacement`
    /// and `PiPVideoCompositor.OverlayEntry`.
    func test_buildPiPInstructions_freeTransformPropagatesToOverlayEntry() {
        let imageURL = URL(fileURLWithPath: "/tmp/rot.png")
        let ft = FreeTransform(
            positionX: 0.3,
            positionY: 0.7,
            scale: 1.5,
            rotationDegrees: 45,
            opacity: 0.8
        )
        let placements: [CompositionBuilder.PiPInstructionPlacement] = [
            .init(
                source: .image(url: imageURL),
                composedStart: 0.0,
                composedEnd: 2.0,
                pipLayout: nil,
                freeTransform: ft
            )
        ]
        let instructions = CompositionBuilder.buildPiPInstructions(
            primaryTrackID: 100,
            overlayPlacements: placements,
            totalDuration: 2.0,
            composedInfos: [],
            subtitleRenderer: nil,
            chapterRenderer: nil
        )
        let entry = instructions.flatMap(\.overlays).first
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.freeTransform?.positionX ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(entry?.freeTransform?.positionY ?? 0, 0.7, accuracy: 0.0001)
        XCTAssertEqual(entry?.freeTransform?.scale ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(entry?.freeTransform?.rotationDegrees ?? 0, 45, accuracy: 0.0001)
        XCTAssertEqual(entry?.freeTransform?.opacity ?? 0, 0.8, accuracy: 0.0001)
    }

    /// Two independent image overlays whose time ranges overlap must
    /// both appear in the overlapping interval's `overlays` array,
    /// preserved in placement order so the top-most layer wins — this
    /// is what the export pipeline uses to bake stacked still images.
    func test_buildPiPInstructions_stacksMultipleImageOverlays() {
        let urlA = URL(fileURLWithPath: "/tmp/a.png")
        let urlB = URL(fileURLWithPath: "/tmp/b.png")
        let placements: [CompositionBuilder.PiPInstructionPlacement] = [
            .init(
                source: .image(url: urlA),
                composedStart: 0.0,
                composedEnd: 3.0,
                pipLayout: nil,
                freeTransform: nil
            ),
            .init(
                source: .image(url: urlB),
                composedStart: 1.0,
                composedEnd: 2.0,
                pipLayout: nil,
                freeTransform: nil
            )
        ]
        let instructions = CompositionBuilder.buildPiPInstructions(
            primaryTrackID: 100,
            overlayPlacements: placements,
            totalDuration: 3.0,
            composedInfos: [],
            subtitleRenderer: nil,
            chapterRenderer: nil
        )
        // Interval [1, 2] must contain both images.
        let overlapping = instructions.first { inst in
            inst.timeRange.start.seconds > 0.99 && inst.timeRange.start.seconds < 1.01
        }
        XCTAssertNotNil(overlapping, "expected an interval starting at t=1.0")
        XCTAssertEqual(overlapping?.overlays.count, 2)
        let sources: [URL?] = overlapping?.overlays.map { entry in
            if case .image(let url) = entry.source { return url } else { return nil }
        } ?? []
        XCTAssertEqual(sources, [urlA, urlB], "expected both image URLs in placement order")
        // Stacked images require only the primary track from AV.
        let required = (overlapping?.requiredSourceTrackIDs ?? [])
            .compactMap { ($0 as? NSNumber)?.int32Value }
        XCTAssertEqual(required, [100])
    }
}
