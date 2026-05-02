import XCTest
import CoreGraphics
@testable import CuttiKit

final class FreeTransformTests: XCTestCase {
    func test_identity_hasCenteredPositionAndUnitScale() {
        let t = FreeTransform.identity
        XCTAssertEqual(t.positionX, 0.5)
        XCTAssertEqual(t.positionY, 0.5)
        XCTAssertEqual(t.scale, 1.0)
        XCTAssertEqual(t.rotationDegrees, 0)
        XCTAssertEqual(t.opacity, 1.0)
    }

    func test_fitSize_preservesAspect() {
        let fit = FreeTransformGeometry.fitSize(
            sourceSize: CGSize(width: 1920, height: 1080),
            canvasSize: CGSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(fit.width, 1000, accuracy: 0.001)
        XCTAssertEqual(fit.height, 562.5, accuracy: 0.001)
    }

    func test_fitSize_returnsZeroForZeroSource() {
        let fit = FreeTransformGeometry.fitSize(
            sourceSize: .zero,
            canvasSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(fit, .zero)
    }
}
