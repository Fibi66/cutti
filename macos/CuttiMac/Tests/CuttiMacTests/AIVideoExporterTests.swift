import XCTest
@testable import CuttiMac

final class AIVideoExporterTests: XCTestCase {

    func test_estimateRemainingSeconds_returnsNilBeforeWarmup() {
        // Less than 2% complete — no estimate yet.
        XCTAssertNil(AIVideoExporter.estimateRemainingSeconds(fraction: 0.01, elapsedSeconds: 5))
        // Less than 1s elapsed — encoder hasn't ramped up.
        XCTAssertNil(AIVideoExporter.estimateRemainingSeconds(fraction: 0.5, elapsedSeconds: 0.3))
        // Both gates fail.
        XCTAssertNil(AIVideoExporter.estimateRemainingSeconds(fraction: 0, elapsedSeconds: 0))
    }

    func test_estimateRemainingSeconds_extrapolatesLinearly() {
        // 25% complete in 10s -> total ~40s, ~30s remaining.
        let eta = AIVideoExporter.estimateRemainingSeconds(fraction: 0.25, elapsedSeconds: 10)
        XCTAssertNotNil(eta)
        XCTAssertEqual(eta!, 30, accuracy: 0.001)
    }

    func test_estimateRemainingSeconds_clampsAtZeroWhenComplete() {
        // 100% complete shouldn't report a negative value.
        let eta = AIVideoExporter.estimateRemainingSeconds(fraction: 1.0, elapsedSeconds: 60)
        XCTAssertEqual(eta, 0)
    }

    func test_estimateRemainingSeconds_handlesSlowStart() {
        // 5% complete in 30s -> total ~600s, ~570s remaining (long export).
        let eta = AIVideoExporter.estimateRemainingSeconds(fraction: 0.05, elapsedSeconds: 30)
        XCTAssertNotNil(eta)
        XCTAssertEqual(eta!, 570, accuracy: 0.001)
    }
}
