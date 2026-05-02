import XCTest
@testable import CuttiMac

final class TimecodeFormatterTests: XCTestCase {
    func test_string_formatsSMPTEStyleTimecodeAtThirtyFPS() {
        XCTAssertEqual(TimecodeFormatter.string(seconds: 65.4, fps: 30), "00:01:05:12")
    }

    func test_string_keepsThirtyFPSBoundaryFramesBelowDisplayCount() {
        XCTAssertEqual(TimecodeFormatter.string(seconds: 1.9999999999999998, fps: 30), "00:00:01:29")
    }

    func test_string_usesActualFractionalFPSForTwentyThreeNineSevenSix() {
        XCTAssertEqual(TimecodeFormatter.string(seconds: 1.5, fps: 23.976), "00:00:01:11")
    }

    func test_string_usesActualFractionalFPSForTwentyNineNineSeven() {
        XCTAssertEqual(TimecodeFormatter.string(seconds: 1.5, fps: 29.97), "00:00:01:14")
    }

    func test_string_keepsFractionalFPSBoundaryFramesBelowDisplayCount() {
        XCTAssertEqual(TimecodeFormatter.string(seconds: 1.9999999999999998, fps: 23.976), "00:00:01:23")
        XCTAssertEqual(TimecodeFormatter.string(seconds: 1.9999999999999998, fps: 29.97), "00:00:01:29")
    }

    func test_string_clampsNegativeSecondsToZero() {
        XCTAssertEqual(TimecodeFormatter.string(seconds: -2, fps: 30), "00:00:00:00")
    }

    func test_string_clampsNonFiniteFPSValuesToMinimumFrameRate() {
        XCTAssertEqual(TimecodeFormatter.string(seconds: 1.9, fps: .nan), "00:00:01:00")
        XCTAssertEqual(TimecodeFormatter.string(seconds: 1.9, fps: .infinity), "00:00:01:00")
    }
}
