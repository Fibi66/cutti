import XCTest
import CuttiKit
@testable import CuttiMac

final class FreeTransformGeometryTests: XCTestCase {

    private let canvas = CGSize(width: 1920, height: 1080)
    private let source = CGSize(width: 1000, height: 500)  // 2:1

    func test_fitSize_aspectFitsInsideCanvas() {
        let fit = FreeTransformGeometry.fitSize(sourceSize: source, canvasSize: canvas)
        // 2:1 source on 16:9 canvas: limited by height? No — height
        // ratio is 1080/500=2.16, width ratio 1920/1000=1.92. Min=1.92.
        XCTAssertEqual(fit.width, 1920, accuracy: 0.5)
        XCTAssertEqual(fit.height, 960, accuracy: 0.5)
    }

    func test_fitSize_zeroSourceReturnsZero() {
        let fit = FreeTransformGeometry.fitSize(sourceSize: .zero, canvasSize: canvas)
        XCTAssertEqual(fit, .zero)
    }

    func test_identityTransform_centersFitSizeOnCanvas() {
        let t = FreeTransformGeometry.ciTransform(
            sourceSize: source,
            canvasSize: canvas,
            transform: .identity
        )
        // A corner at source (0,0) after identity transform should land
        // at the bottom-left corner of the fit rect centered in canvas.
        // Fit = 1920×960, centered → x range [0, 1920], y range (bl)
        // [(1080-960)/2, (1080+960)/2] = [60, 1020].
        let corner = CGPoint.zero.applying(t)
        XCTAssertEqual(corner.x, 0, accuracy: 1.0)
        XCTAssertEqual(corner.y, 60, accuracy: 1.0)
        let oppCorner = CGPoint(x: source.width, y: source.height).applying(t)
        XCTAssertEqual(oppCorner.x, 1920, accuracy: 1.0)
        XCTAssertEqual(oppCorner.y, 1020, accuracy: 1.0)
    }

    func test_scaleTwo_doublesDisplaySize() {
        var ft = FreeTransform.identity
        ft.scale = 2.0
        let t = FreeTransformGeometry.ciTransform(
            sourceSize: source,
            canvasSize: canvas,
            transform: ft
        )
        // Source corner-to-corner distance × scale.
        let corner0 = CGPoint.zero.applying(t)
        let corner1 = CGPoint(x: source.width, y: source.height).applying(t)
        let dx = corner1.x - corner0.x
        XCTAssertEqual(dx, 1920 * 2, accuracy: 1.0)
    }

    func test_positionOffCanvasProducesCorrectTranslation() {
        var ft = FreeTransform.identity
        ft.positionX = 0.25
        ft.positionY = 0.75
        let t = FreeTransformGeometry.ciTransform(
            sourceSize: source,
            canvasSize: canvas,
            transform: ft
        )
        // Center of source after transform = canvas point, flipped y.
        let center = CGPoint(x: source.width / 2, y: source.height / 2).applying(t)
        XCTAssertEqual(center.x, 1920 * 0.25, accuracy: 1.0)
        XCTAssertEqual(center.y, 1080 * (1 - 0.75), accuracy: 1.0)
    }

    func test_rotation90_mapsTopEdgeToLeftEdge() {
        var ft = FreeTransform.identity
        ft.rotationDegrees = 90  // clockwise in UI → source top edge
                                 // ends up on the canvas's LEFT edge.
        let t = FreeTransformGeometry.ciTransform(
            sourceSize: source,
            canvasSize: canvas,
            transform: ft
        )
        // Midpoint of the source's TOP edge (x=w/2, y=0 in source space)
        // after 90° clockwise rotation sits on the canvas's LEFT side
        // of the layer's display rect.
        let topMid = CGPoint(x: source.width / 2, y: 0).applying(t)
        let centerMid = CGPoint(x: source.width / 2, y: source.height / 2).applying(t)
        // In canvas coords, topMid should be strictly LEFT of center.
        XCTAssertLessThan(topMid.x, centerMid.x)
        // And roughly at the same height (y) since rotation is about
        // the center (tolerance = 1px for FP).
        XCTAssertEqual(topMid.y, centerMid.y, accuracy: 1.0)
    }
}
