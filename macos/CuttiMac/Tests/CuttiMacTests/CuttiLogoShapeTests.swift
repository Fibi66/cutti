import CoreGraphics
import SwiftUI
import XCTest
@testable import CuttiMac

/// Validates that the canonical Cutti logo SVG parses into the exact
/// five sub-paths we reference by name, lands in the expected SVG
/// coordinate ranges, and fits inside the declared viewBox once rendered
/// into a target frame. These are the invariants ``BlinkingEyesView``
/// depends on for blink anchoring and sizing to stay correct.
final class CuttiLogoShapeTests: XCTestCase {

    // MARK: - Parser-level invariants

    func testRawPathParsesIntoFiveNonEmptySubpaths() throws {
        let subpaths = CuttiLogoPathData.subpaths
        XCTAssertEqual(
            subpaths.count,
            CuttiLogoPathData.Part.allCases.count,
            "Cutti logo must parse into one sub-path per named Part."
        )
        for (index, path) in subpaths.enumerated() {
            let bbox = path.boundingRect
            XCTAssertFalse(
                path.isEmpty,
                "Sub-path #\(index) must contain geometry."
            )
            XCTAssertGreaterThan(
                bbox.width, 0,
                "Sub-path #\(index) bounding box must have positive width."
            )
            XCTAssertGreaterThan(
                bbox.height, 0,
                "Sub-path #\(index) bounding box must have positive height."
            )
        }
    }

    func testUnsupportedCommandRaisesDiagnostic() {
        XCTAssertThrowsError(try SVGPathParser.parseSubpaths("M0 0 Q1 1 2 2")) { error in
            guard let parserError = error as? SVGPathParserError else {
                return XCTFail("Expected SVGPathParserError, got \(error)")
            }
            if case .unsupportedCommand(let c, _) = parserError {
                XCTAssertEqual(c, "Q")
            } else {
                XCTFail("Expected .unsupportedCommand, got \(parserError)")
            }
        }
    }

    func testEmptyPathRaises() {
        XCTAssertThrowsError(try SVGPathParser.parseSubpaths("")) { error in
            XCTAssertTrue(error is SVGPathParserError)
        }
    }

    // MARK: - Per-part geometry

    func testEyeBoundingBoxesMatchSpec() {
        let leftEye  = CuttiLogoPathData.boundingBox(of: .leftEye)
        let rightEye = CuttiLogoPathData.boundingBox(of: .rightEye)

        // Spec: left eye x≈175–310, y≈338–876. The spec numbers trace
        // the `M` endpoints; the actual hand-drawn cubic bulges a bit
        // further (left side reaches ~148) so we accept ±40 pt of
        // slack. Anything looser would hide a real sub-path mixup.
        XCTAssertEqual(leftEye.minX,  175, accuracy: 40)
        XCTAssertEqual(leftEye.maxX,  310, accuracy: 40)
        XCTAssertEqual(leftEye.minY,  338, accuracy: 10)
        XCTAssertEqual(leftEye.maxY,  876, accuracy: 10)

        // Spec: right eye x≈787–944, y≈339–876.
        XCTAssertEqual(rightEye.minX, 787, accuracy: 40)
        XCTAssertEqual(rightEye.maxX, 944, accuracy: 40)
        XCTAssertEqual(rightEye.minY, 339, accuracy: 10)
        XCTAssertEqual(rightEye.maxY, 876, accuracy: 10)

        // The eyes live on the same horizontal band — their vertical
        // centres should agree to within a few points. This is what
        // makes blink anchoring symmetric.
        XCTAssertEqual(leftEye.midY, rightEye.midY, accuracy: 5.0)

        // Each eye is tall and narrow (~1:3.5+ aspect). A regression
        // that flipped a sub-path or swapped coords would turn the
        // bounding box squat; guard against that.
        XCTAssertGreaterThan(leftEye.height  / leftEye.width,  3.0)
        XCTAssertGreaterThan(rightEye.height / rightEye.width, 3.0)
    }

    func testBrowsSitAboveEyesAndNoseSitsNearEyeBottoms() {
        let rightBrow = CuttiLogoPathData.boundingBox(of: .rightBrow)
        let leftBrow  = CuttiLogoPathData.boundingBox(of: .leftBrow)
        let leftEye   = CuttiLogoPathData.boundingBox(of: .leftEye)
        let rightEye  = CuttiLogoPathData.boundingBox(of: .rightEye)
        let nose      = CuttiLogoPathData.boundingBox(of: .nose)

        XCTAssertLessThan(rightBrow.maxY, leftEye.minY,
                          "Right brow must sit entirely above the eyes.")
        XCTAssertLessThan(leftBrow.maxY, leftEye.minY,
                          "Left brow must sit entirely above the eyes.")

        // The nose's visual start is `M563.411 868.007`, which sits
        // just slightly above the bottom of the eye curve bulge (~876).
        // What matters is that the nose hook lives in the lower-centre
        // region, not that its tight bbox clears every pixel of the
        // eyes. Assert the nose is centred horizontally between the
        // two eyes and extends well below them.
        XCTAssertGreaterThan(nose.midX, leftEye.maxX,
                             "Nose should sit to the right of the left eye.")
        XCTAssertLessThan(nose.midX, rightEye.minX,
                          "Nose should sit to the left of the right eye.")
        XCTAssertGreaterThan(nose.maxY, leftEye.maxY + 100,
                             "Nose must extend well below the eyes.")
    }

    // MARK: - Render-time invariants

    func testAllSubpathsFitWithinViewBox() {
        let viewBox = CGRect(origin: .zero,
                             size: CuttiLogoPathData.viewBox)
        // A small negative epsilon absorbs the single SVG coordinate
        // that goes slightly below 0 (right brow starts at y≈0.625 and
        // the exporter emits -0.105 for one control point). Anything
        // beyond this would be a real out-of-viewBox bug.
        let epsilon: CGFloat = 2.0
        for (index, path) in CuttiLogoPathData.subpaths.enumerated() {
            let bbox = path.boundingRect
            XCTAssertGreaterThanOrEqual(bbox.minX, viewBox.minX - epsilon,
                                        "Sub-path #\(index) minX out of viewBox.")
            XCTAssertGreaterThanOrEqual(bbox.minY, viewBox.minY - epsilon,
                                        "Sub-path #\(index) minY out of viewBox.")
            XCTAssertLessThanOrEqual(bbox.maxX, viewBox.maxX + epsilon,
                                     "Sub-path #\(index) maxX out of viewBox.")
            XCTAssertLessThanOrEqual(bbox.maxY, viewBox.maxY + epsilon,
                                     "Sub-path #\(index) maxY out of viewBox.")
        }
    }

    func testShapeDrawsAllPartsWithinTargetFrame() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let shape = CuttiLogoPartsShape(parts: CuttiLogoPathData.Part.allCases)
        let rendered = shape.path(in: frame).boundingRect
        let epsilon: CGFloat = 0.5
        XCTAssertGreaterThanOrEqual(rendered.minX, frame.minX - epsilon)
        XCTAssertGreaterThanOrEqual(rendered.minY, frame.minY - epsilon)
        XCTAssertLessThanOrEqual(rendered.maxX, frame.maxX + epsilon)
        XCTAssertLessThanOrEqual(rendered.maxY, frame.maxY + epsilon)
        XCTAssertGreaterThan(rendered.width,  frame.width  * 0.8,
                             "Rendered logo should fill most of its frame horizontally.")
        XCTAssertGreaterThan(rendered.height, frame.height * 0.8,
                             "Rendered logo should fill most of its frame vertically.")
    }

    func testAnchorsCenterOnEachEye() {
        let leftAnchor  = CuttiLogoPathData.anchor(of: .leftEye)
        let rightAnchor = CuttiLogoPathData.anchor(of: .rightEye)

        // Unit coordinates: left eye centre ≈ 242/1064 = 0.227,
        // right ≈ 864/1064 = 0.812, both at y ≈ 607/1094 = 0.555.
        XCTAssertEqual(leftAnchor.x,  0.227, accuracy: 0.02)
        XCTAssertEqual(rightAnchor.x, 0.812, accuracy: 0.02)
        XCTAssertEqual(leftAnchor.y,  0.555, accuracy: 0.02)
        XCTAssertEqual(rightAnchor.y, 0.555, accuracy: 0.02)
    }
}
