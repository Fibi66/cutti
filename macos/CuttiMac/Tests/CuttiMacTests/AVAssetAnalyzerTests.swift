import XCTest
@testable import CuttiMac

final class AVAssetAnalyzerTests: XCTestCase {
    func test_analyze_readsDurationDimensionsFPSAndAudio() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/sample-h264-640x360.mp4")

        let summary = try await AVAssetAnalyzer().analyze(url: fixture)

        XCTAssertEqual(summary.width, 640)
        XCTAssertEqual(summary.height, 360)
        XCTAssertGreaterThan(summary.durationSeconds, 0.9)
        XCTAssertGreaterThan(summary.nominalFPS, 29.0)
        XCTAssertTrue(summary.hasAudio)
    }
}
