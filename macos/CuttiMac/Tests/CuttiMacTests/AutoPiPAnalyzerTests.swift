import XCTest
@testable import CuttiMac

final class AutoPiPAnalyzerTests: XCTestCase {

    // MARK: - Presenter decision

    func test_decidePresenter_emptySamples_returnsFalse() {
        let result = AutoPiPAnalyzer.decidePresenter(samples: [])
        XCTAssertFalse(result.isPresenterCam)
        XCTAssertEqual(result.confidence, 0)
    }

    func test_decidePresenter_strongPresenterCam_qualifies() {
        // 5/5 frames have a centered face 30% tall → classic talking head.
        let face = AutoPiPAnalyzer.FaceSample(
            bbox: CGRect(x: 0.35, y: 0.35, width: 0.30, height: 0.30)
        )
        let samples = Array(repeating: AutoPiPAnalyzer.PresenterFrameSample(faces: [face]), count: 5)
        let result = AutoPiPAnalyzer.decidePresenter(samples: samples)
        XCTAssertTrue(result.isPresenterCam)
        XCTAssertEqual(result.medianFaceHeightFraction, 0.30, accuracy: 0.001)
        XCTAssertGreaterThan(result.confidence, 0.6)
    }

    func test_decidePresenter_tinyFaces_rejected() {
        // Faces present but only 8% tall — below threshold.
        let face = AutoPiPAnalyzer.FaceSample(
            bbox: CGRect(x: 0.45, y: 0.45, width: 0.08, height: 0.08)
        )
        let samples = Array(repeating: AutoPiPAnalyzer.PresenterFrameSample(faces: [face]), count: 5)
        XCTAssertFalse(AutoPiPAnalyzer.decidePresenter(samples: samples).isPresenterCam)
    }

    func test_decidePresenter_lowFaceHitRate_rejected() {
        // Only 2/5 frames have a face.
        let face = AutoPiPAnalyzer.FaceSample(
            bbox: CGRect(x: 0.4, y: 0.4, width: 0.25, height: 0.25)
        )
        let withFace = AutoPiPAnalyzer.PresenterFrameSample(faces: [face])
        let without = AutoPiPAnalyzer.PresenterFrameSample(faces: [])
        let samples = [withFace, without, without, withFace, without]
        XCTAssertFalse(AutoPiPAnalyzer.decidePresenter(samples: samples).isPresenterCam)
    }

    func test_decidePresenter_movingFace_rejected() {
        // Large face but jumps across every quadrant — not stationary.
        let positions: [CGRect] = [
            CGRect(x: 0.05, y: 0.05, width: 0.20, height: 0.20), // BL
            CGRect(x: 0.75, y: 0.05, width: 0.20, height: 0.20), // BR
            CGRect(x: 0.05, y: 0.75, width: 0.20, height: 0.20), // TL
            CGRect(x: 0.75, y: 0.75, width: 0.20, height: 0.20), // TR
            CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)  // center
        ]
        let samples = positions.map {
            AutoPiPAnalyzer.PresenterFrameSample(faces: [AutoPiPAnalyzer.FaceSample(bbox: $0)])
        }
        XCTAssertFalse(AutoPiPAnalyzer.decidePresenter(samples: samples).isPresenterCam)
    }

    func test_decidePresenter_usesLargestFaceWhenMultiplePeople() {
        // Small background face + big foreground face. Should use the big one.
        let big = AutoPiPAnalyzer.FaceSample(bbox: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3))
        let small = AutoPiPAnalyzer.FaceSample(bbox: CGRect(x: 0.7, y: 0.7, width: 0.05, height: 0.05))
        let samples = Array(
            repeating: AutoPiPAnalyzer.PresenterFrameSample(faces: [small, big]),
            count: 5
        )
        let r = AutoPiPAnalyzer.decidePresenter(samples: samples)
        XCTAssertTrue(r.isPresenterCam)
        XCTAssertEqual(r.medianFaceHeightFraction, 0.30, accuracy: 0.001)
    }

    // MARK: - Corner decision

    func test_decideCorner_picksLowestDensity() {
        let s = AutoPiPAnalyzer.DensityFrameSample(perCorner: [
            .topLeft: 0.8,
            .topRight: 0.2, // winner
            .bottomLeft: 0.6,
            .bottomRight: 0.7
        ])
        let (corner, _) = AutoPiPAnalyzer.decideCorner(samples: [s])
        XCTAssertEqual(corner, .topRight)
    }

    func test_decideCorner_tiesBreakToBottomRight() {
        let s = AutoPiPAnalyzer.DensityFrameSample(perCorner: [
            .topLeft: 0.10,
            .topRight: 0.10,
            .bottomLeft: 0.10,
            .bottomRight: 0.10
        ])
        let (corner, _) = AutoPiPAnalyzer.decideCorner(samples: [s])
        XCTAssertEqual(corner, .bottomRight)
    }

    func test_decideCorner_nearTiesPreferBottomRight() {
        // topLeft is marginally lower but within tolerance — prefer bottomRight.
        let s = AutoPiPAnalyzer.DensityFrameSample(perCorner: [
            .topLeft: 0.100,
            .topRight: 0.500,
            .bottomLeft: 0.400,
            .bottomRight: 0.105
        ])
        let (corner, _) = AutoPiPAnalyzer.decideCorner(samples: [s])
        XCTAssertEqual(corner, .bottomRight)
    }

    func test_decideCorner_aggregatesAcrossSamples() {
        // bottomRight wins overall even though another corner wins frame 1.
        let s1 = AutoPiPAnalyzer.DensityFrameSample(perCorner: [
            .topLeft: 0.2, .topRight: 0.9, .bottomLeft: 0.9, .bottomRight: 0.9
        ])
        let s2 = AutoPiPAnalyzer.DensityFrameSample(perCorner: [
            .topLeft: 0.9, .topRight: 0.9, .bottomLeft: 0.9, .bottomRight: 0.0
        ])
        let s3 = AutoPiPAnalyzer.DensityFrameSample(perCorner: [
            .topLeft: 0.9, .topRight: 0.9, .bottomLeft: 0.9, .bottomRight: 0.0
        ])
        let (corner, _) = AutoPiPAnalyzer.decideCorner(samples: [s1, s2, s3])
        XCTAssertEqual(corner, .bottomRight)
    }

    // MARK: - Shape decision

    func test_decideShape_squareAspectPicksCircle() {
        XCTAssertEqual(AutoPiPAnalyzer.decideShape(sourceAspect: 1.0), .circle)
        XCTAssertEqual(AutoPiPAnalyzer.decideShape(sourceAspect: 1.1), .circle)
    }

    func test_decideShape_wideAspectPicksRoundedSquare() {
        XCTAssertEqual(AutoPiPAnalyzer.decideShape(sourceAspect: 16.0 / 9.0), .roundedSquare)
    }

    func test_decideShape_invalidAspectFallsBackToRoundedSquare() {
        XCTAssertEqual(AutoPiPAnalyzer.decideShape(sourceAspect: 0), .roundedSquare)
        XCTAssertEqual(AutoPiPAnalyzer.decideShape(sourceAspect: -1), .roundedSquare)
        XCTAssertEqual(AutoPiPAnalyzer.decideShape(sourceAspect: .nan), .roundedSquare)
    }

    // MARK: - Helpers

    func test_quadrant_bucketing() {
        // Vision coords: origin bottom-left.
        XCTAssertEqual(AutoPiPAnalyzer.quadrant(forNormalizedPoint: CGPoint(x: 0.1, y: 0.9)), .topLeft)
        XCTAssertEqual(AutoPiPAnalyzer.quadrant(forNormalizedPoint: CGPoint(x: 0.9, y: 0.9)), .topRight)
        XCTAssertEqual(AutoPiPAnalyzer.quadrant(forNormalizedPoint: CGPoint(x: 0.1, y: 0.1)), .bottomLeft)
        XCTAssertEqual(AutoPiPAnalyzer.quadrant(forNormalizedPoint: CGPoint(x: 0.9, y: 0.1)), .bottomRight)
    }

    func test_median_evenAndOdd() {
        XCTAssertEqual(AutoPiPAnalyzer.median([1, 2, 3]), 2, accuracy: 0.001)
        XCTAssertEqual(AutoPiPAnalyzer.median([1, 2, 3, 4]), 2.5, accuracy: 0.001)
        XCTAssertEqual(AutoPiPAnalyzer.median([]), 0, accuracy: 0.001)
    }
}
