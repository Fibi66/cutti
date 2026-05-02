import XCTest
@testable import CuttiKit


final class PiPGeometryTests: XCTestCase {

    private let canvas = CGSize(width: 1920, height: 1080)
    private let sourceFrame = CGSize(width: 1920, height: 1080)

    // MARK: - Corner placement

    func test_compute_bottomRight_placesRectInBottomRightCorner() {
        let layout = PiPLayout(
            shape: .roundedSquare,
            corner: .bottomRight,
            sizeFraction: 0.25,
            insetFraction: 0.025,
            borderWidthPx: 0,
            borderColorHex: nil,
            shadowEnabled: false
        )

        let g = PiPGeometry.compute(
            layout: layout,
            canvasSize: canvas,
            sourceFrameSize: sourceFrame
        )

        let expectedH: CGFloat = 1080 * 0.25
        let expectedInset: CGFloat = 1080 * 0.025
        XCTAssertEqual(g.rect.height, expectedH, accuracy: 1e-6)
        XCTAssertEqual(g.rect.width, expectedH, accuracy: 1e-6)  // square-proportioned
        XCTAssertEqual(g.rect.maxX, 1920 - expectedInset, accuracy: 1e-6)
        XCTAssertEqual(g.rect.maxY, 1080 - expectedInset, accuracy: 1e-6)
    }

    func test_compute_topLeft_placesRectInTopLeftCorner() {
        let layout = PiPLayout(
            shape: .square,
            corner: .topLeft,
            sizeFraction: 0.2,
            insetFraction: 0.03,
            borderWidthPx: 0,
            borderColorHex: nil,
            shadowEnabled: false
        )
        let g = PiPGeometry.compute(
            layout: layout,
            canvasSize: canvas,
            sourceFrameSize: sourceFrame
        )
        let inset: CGFloat = 1080 * 0.03
        XCTAssertEqual(g.rect.minX, inset, accuracy: 1e-6)
        XCTAssertEqual(g.rect.minY, inset, accuracy: 1e-6)
    }

    func test_compute_topRight_placesRectInTopRightCorner() {
        let layout = PiPLayout(
            shape: .roundedSquare,
            corner: .topRight,
            sizeFraction: 0.3,
            insetFraction: 0.01,
            borderWidthPx: 0,
            borderColorHex: nil,
            shadowEnabled: false
        )
        let g = PiPGeometry.compute(
            layout: layout,
            canvasSize: canvas,
            sourceFrameSize: sourceFrame
        )
        let inset: CGFloat = 1080 * 0.01
        XCTAssertEqual(g.rect.maxX, 1920 - inset, accuracy: 1e-6)
        XCTAssertEqual(g.rect.minY, inset, accuracy: 1e-6)
    }

    func test_compute_bottomLeft_placesRectInBottomLeftCorner() {
        let layout = PiPLayout(
            shape: .circle,
            corner: .bottomLeft,
            sizeFraction: 0.22,
            insetFraction: 0.025,
            borderWidthPx: 0,
            borderColorHex: nil,
            shadowEnabled: false
        )
        let g = PiPGeometry.compute(
            layout: layout,
            canvasSize: canvas,
            sourceFrameSize: sourceFrame
        )
        let inset: CGFloat = 1080 * 0.025
        XCTAssertEqual(g.rect.minX, inset, accuracy: 1e-6)
        XCTAssertEqual(g.rect.maxY, 1080 - inset, accuracy: 1e-6)
    }

    // MARK: - Corner radius by shape

    func test_compute_circle_cornerRadiusIsHalfMinSide() {
        let layout = PiPLayout.default
        let g = PiPGeometry.compute(
            layout: PiPLayout(
                shape: .circle,
                corner: .bottomRight,
                sizeFraction: 0.2,
                insetFraction: 0,
                borderWidthPx: 0,
                borderColorHex: nil,
                shadowEnabled: false
            ),
            canvasSize: canvas,
            sourceFrameSize: sourceFrame
        )
        let side: CGFloat = 1080 * 0.2
        XCTAssertEqual(g.cornerRadius, side / 2, accuracy: 1e-6)
        _ = layout
    }

    func test_compute_square_cornerRadiusIsZero() {
        let g = PiPGeometry.compute(
            layout: PiPLayout(
                shape: .square,
                corner: .topLeft,
                sizeFraction: 0.25,
                insetFraction: 0,
                borderWidthPx: 0,
                borderColorHex: nil,
                shadowEnabled: false
            ),
            canvasSize: canvas,
            sourceFrameSize: sourceFrame
        )
        XCTAssertEqual(g.cornerRadius, 0)
    }

    func test_compute_roundedSquare_cornerRadiusIsFractionOfMinSide() {
        let g = PiPGeometry.compute(
            layout: PiPLayout(
                shape: .roundedSquare,
                corner: .bottomRight,
                sizeFraction: 0.2,
                insetFraction: 0,
                borderWidthPx: 0,
                borderColorHex: nil,
                shadowEnabled: false
            ),
            canvasSize: canvas,
            sourceFrameSize: sourceFrame
        )
        let side: CGFloat = 1080 * 0.2
        XCTAssertEqual(g.cornerRadius,
                       side * PiPGeometry.squareRoundedCornerRatio,
                       accuracy: 1e-6)
    }

    // MARK: - Clamping / defensive behavior

    func test_compute_clampsOutOfRangeSizeAndInset() {
        let insane = PiPLayout(
            shape: .roundedSquare,
            corner: .bottomRight,
            sizeFraction: 99.0,     // would overflow canvas
            insetFraction: 99.0,    // would put rect off-canvas
            borderWidthPx: -8,
            borderColorHex: nil,
            shadowEnabled: true
        )
        let g = PiPGeometry.compute(
            layout: insane,
            canvasSize: canvas,
            sourceFrameSize: sourceFrame
        )
        // Clamped via .normalized(): sizeFraction <= maxSizeFraction,
        // insetFraction <= maxInsetFraction, border >= 0.
        XCTAssertLessThanOrEqual(g.rect.height / 1080, PiPLayout.maxSizeFraction + 1e-9)
        XCTAssertGreaterThanOrEqual(g.rect.minX, 0)
        XCTAssertGreaterThanOrEqual(g.rect.minY, 0)
        XCTAssertLessThanOrEqual(g.rect.maxX, 1920)
        XCTAssertLessThanOrEqual(g.rect.maxY, 1080)
        XCTAssertGreaterThanOrEqual(g.borderWidth, 0)
    }

    func test_compute_scaleFactor_matchesTargetHeightOverSourceHeight() {
        let layout = PiPLayout(
            shape: .roundedSquare,
            corner: .bottomRight,
            sizeFraction: 0.2,
            insetFraction: 0,
            borderWidthPx: 0,
            borderColorHex: nil,
            shadowEnabled: false
        )
        let smallerSource = CGSize(width: 960, height: 540)
        let g = PiPGeometry.compute(
            layout: layout,
            canvasSize: canvas,
            sourceFrameSize: smallerSource
        )
        // targetH = 1080 * 0.2 = 216; sourceH = 540; scale = 0.4
        XCTAssertEqual(g.scale, 216.0 / 540.0, accuracy: 1e-9)
    }

    func test_compute_resolutionIndependence_sameFractionalLayout_yieldsSameRelativeRect() {
        // Canvas-normalized layout: same fractional rect on 1080p and
        // 4K so presets don't need to change when resolution changes.
        let layout = PiPLayout(
            shape: .roundedSquare,
            corner: .topRight,
            sizeFraction: 0.22,
            insetFraction: 0.025,
            borderWidthPx: 0,
            borderColorHex: nil,
            shadowEnabled: false
        )
        let hd = PiPGeometry.compute(
            layout: layout,
            canvasSize: CGSize(width: 1920, height: 1080),
            sourceFrameSize: CGSize(width: 1920, height: 1080)
        )
        let uhd = PiPGeometry.compute(
            layout: layout,
            canvasSize: CGSize(width: 3840, height: 2160),
            sourceFrameSize: CGSize(width: 3840, height: 2160)
        )

        // Inset-from-right as fraction of canvas width should match.
        let hdInsetFraction = (1920 - hd.rect.maxX) / 1920
        let uhdInsetFraction = (3840 - uhd.rect.maxX) / 3840
        XCTAssertEqual(hdInsetFraction, uhdInsetFraction, accuracy: 1e-6)

        let hdHeightFraction = hd.rect.height / 1080
        let uhdHeightFraction = uhd.rect.height / 2160
        XCTAssertEqual(hdHeightFraction, uhdHeightFraction, accuracy: 1e-6)
    }
}
