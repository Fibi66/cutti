import XCTest
@testable import CuttiKit

/// Pins behaviour of `AudioEnergyCurve` and its persistence on
/// `AICopilotSnapshot`. The curve is the foundation of the
/// hook-extraction feature and any other loudness-aware AI tool —
/// regressions here cascade to scoring, ranking, and UX.
final class AudioEnergyCurveTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - valueAt: interpolation

    func test_valueAt_emptyCurve_returnsZero() {
        let curve = AudioEnergyCurve(values: [], windowSeconds: 0.5)
        XCTAssertEqual(curve.valueAt(seconds: 0), 0)
        XCTAssertEqual(curve.valueAt(seconds: 5), 0)
    }

    func test_valueAt_zeroWindow_returnsZero() {
        let curve = AudioEnergyCurve(values: [0.5, 0.5], windowSeconds: 0)
        XCTAssertEqual(curve.valueAt(seconds: 0), 0)
    }

    func test_valueAt_negativeTime_returnsZero() {
        let curve = AudioEnergyCurve(values: [0.4, 0.8], windowSeconds: 1.0)
        XCTAssertEqual(curve.valueAt(seconds: -0.5), 0)
    }

    func test_valueAt_outOfRange_returnsZero() {
        let curve = AudioEnergyCurve(values: [0.4, 0.8], windowSeconds: 1.0)
        // Curve only covers [0, 2). Anything past the last sample window is 0.
        XCTAssertEqual(curve.valueAt(seconds: 100), 0)
    }

    func test_valueAt_exactSamplePoint_returnsExactValue() {
        let curve = AudioEnergyCurve(values: [0.2, 0.6, 0.4], windowSeconds: 1.0)
        XCTAssertEqual(curve.valueAt(seconds: 0.0), 0.2, accuracy: 1e-6)
        XCTAssertEqual(curve.valueAt(seconds: 1.0), 0.6, accuracy: 1e-6)
        XCTAssertEqual(curve.valueAt(seconds: 2.0), 0.4, accuracy: 1e-6)
    }

    func test_valueAt_betweenSamples_linearlyInterpolates() {
        let curve = AudioEnergyCurve(values: [0.2, 0.6], windowSeconds: 1.0)
        // halfway between 0.2 and 0.6 → 0.4
        XCTAssertEqual(curve.valueAt(seconds: 0.5), 0.4, accuracy: 1e-6)
        // 25% in → 0.2 * 0.75 + 0.6 * 0.25 = 0.15 + 0.15 = 0.30
        XCTAssertEqual(curve.valueAt(seconds: 0.25), 0.30, accuracy: 1e-6)
    }

    func test_valueAt_lastSampleClampsForward() {
        // At t = (count - 1) * windowSeconds we land exactly on the
        // final sample; just inside that, interpolation must clamp the
        // upper neighbour to the same final sample (no out-of-bounds).
        let curve = AudioEnergyCurve(values: [0.2, 0.6], windowSeconds: 1.0)
        XCTAssertEqual(curve.valueAt(seconds: 1.0), 0.6, accuracy: 1e-6)
    }

    // MARK: - peakIn

    func test_peakIn_findsMaximumInRange() {
        let curve = AudioEnergyCurve(values: [0.1, 0.4, 0.9, 0.3, 0.2], windowSeconds: 1.0)
        XCTAssertEqual(curve.peakIn(startSeconds: 1.0, endSeconds: 3.0), 0.9, accuracy: 1e-6)
    }

    func test_peakIn_invertedRange_returnsZero() {
        let curve = AudioEnergyCurve(values: [0.1, 0.9], windowSeconds: 1.0)
        XCTAssertEqual(curve.peakIn(startSeconds: 5.0, endSeconds: 1.0), 0)
    }

    func test_peakIn_emptyCurve_returnsZero() {
        let curve = AudioEnergyCurve(values: [], windowSeconds: 0.5)
        XCTAssertEqual(curve.peakIn(startSeconds: 0, endSeconds: 10), 0)
    }

    func test_peakIn_clampsToCurveBounds() {
        // Range overhangs the right edge — should still find the
        // global max within the available samples.
        let curve = AudioEnergyCurve(values: [0.1, 0.9, 0.2], windowSeconds: 1.0)
        XCTAssertEqual(curve.peakIn(startSeconds: 0, endSeconds: 99), 0.9, accuracy: 1e-6)
    }

    // MARK: - globalPeak

    func test_globalPeak_emptyCurve_isZero() {
        XCTAssertEqual(AudioEnergyCurve(values: [], windowSeconds: 0.5).globalPeak, 0)
    }

    func test_globalPeak_returnsMaximum() {
        let curve = AudioEnergyCurve(values: [0.1, 0.7, 0.4, 0.5], windowSeconds: 0.5)
        XCTAssertEqual(curve.globalPeak, 0.7, accuracy: 1e-6)
    }

    // MARK: - Codable round-trip

    func test_codec_roundTripPreservesValues() throws {
        let original = AudioEnergyCurve(
            values: [0.0, 0.123_45, 0.5, 0.999, 0.0],
            windowSeconds: 0.5
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AudioEnergyCurve.self, from: data)
        XCTAssertEqual(decoded.values, original.values)
        XCTAssertEqual(decoded.windowSeconds, original.windowSeconds, accuracy: 1e-9)
    }

    // MARK: - AICopilotSnapshot integration

    func test_snapshot_roundTripPreservesEnergyCurve() throws {
        let snapshot = AICopilotSnapshot(
            semanticTags: ["Talking Head"],
            issues: [],
            suggestions: [],
            markers: [],
            audioEnergyCurve: AudioEnergyCurve(
                values: [0.1, 0.4, 0.7],
                windowSeconds: 0.5
            )
        )
        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(AICopilotSnapshot.self, from: data)
        XCTAssertEqual(decoded.audioEnergyCurve?.values, [0.1, 0.4, 0.7])
        XCTAssertEqual(decoded.audioEnergyCurve?.windowSeconds ?? 0, 0.5, accuracy: 1e-9)
    }

    func test_snapshot_legacyJSON_withoutEnergyCurve_decodesAsNil() throws {
        // A snapshot saved by an older Cutti build (no audioEnergyCurve
        // key in the JSON) must still decode cleanly so existing
        // projects don't break.
        let legacy = """
        {
            "semanticTags": ["Talking Head"],
            "issues": [],
            "suggestions": [],
            "markers": []
        }
        """
        let data = Data(legacy.utf8)
        let decoded = try decoder.decode(AICopilotSnapshot.self, from: data)
        XCTAssertNil(decoded.audioEnergyCurve)
    }
}
