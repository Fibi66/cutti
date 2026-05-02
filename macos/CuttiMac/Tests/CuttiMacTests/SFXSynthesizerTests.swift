import XCTest
@testable import CuttiMac

/// Smoke tests for the built-in SFX synthesizer. We don't try to
/// measure spectral accuracy — we just verify every generator:
///   1. Produces a non-empty buffer
///   2. At roughly the advertised duration (±5% — generators may
///      round sample counts)
///   3. Normalized peak stays within [0.5, 0.95] — loud enough to
///      hear without clipping downstream mixes
///   4. Contains non-trivial energy (RMS > 0.01) so we catch silent
///      outputs (a common failure mode when an envelope multiplies
///      by zero everywhere)
///   5. Is deterministic — SFXSynthesizer uses a seeded PRNG, so the
///      same kind re-rendered must produce byte-identical samples
final class SFXSynthesizerTests: XCTestCase {
    func test_allKindsProduceValidBuffers() {
        for kind in SFXKind.allCases {
            let samples = SFXSynthesizer.render(kind)
            let def = SFXCatalog.definition(for: kind)
            let expected = Int(def.durationSeconds * SFXSynthesizer.sampleRate)
            let tolerance = max(200, Int(Double(expected) * 0.05))

            XCTAssertGreaterThan(samples.count, 0, "\(kind.rawValue): empty buffer")
            XCTAssertLessThanOrEqual(abs(samples.count - expected), tolerance,
                "\(kind.rawValue): sample count \(samples.count) vs expected \(expected)")

            var peak: Float = 0
            var sumSq: Double = 0
            for s in samples {
                peak = max(peak, abs(s))
                sumSq += Double(s) * Double(s)
            }
            let rms = sqrt(sumSq / Double(samples.count))
            XCTAssertLessThanOrEqual(peak, 0.96, "\(kind.rawValue): peak \(peak) may clip")
            XCTAssertGreaterThanOrEqual(peak, 0.5, "\(kind.rawValue): peak \(peak) too quiet")
            XCTAssertGreaterThan(rms, 0.01, "\(kind.rawValue): RMS \(rms) suggests silent output")
        }
    }

    func test_rendersAreDeterministic() {
        for kind in SFXKind.allCases {
            let a = SFXSynthesizer.render(kind)
            let b = SFXSynthesizer.render(kind)
            XCTAssertEqual(a.count, b.count, "\(kind.rawValue): non-deterministic length")
            // Sample-compare in chunks so a flake produces a readable failure.
            if a.count == b.count {
                var maxDiff: Float = 0
                for i in 0..<a.count { maxDiff = max(maxDiff, abs(a[i] - b[i])) }
                XCTAssertEqual(maxDiff, 0, accuracy: 0,
                    "\(kind.rawValue): non-deterministic samples (max diff \(maxDiff))")
            }
        }
    }

    func test_catalogCoversAllKinds() {
        // Every SFXKind must have a catalog entry — the library sheet
        // looks them up by kind, and `SFXCatalog.definition(for:)`
        // traps on missing entries.
        for kind in SFXKind.allCases {
            let def = SFXCatalog.definition(for: kind)
            XCTAssertFalse(def.displayKey.isEmpty, "\(kind.rawValue): missing displayKey")
            XCTAssertFalse(def.symbol.isEmpty, "\(kind.rawValue): missing SF Symbol name")
            XCTAssertGreaterThan(def.durationSeconds, 0, "\(kind.rawValue): zero duration")
            // At least one tag per language so search works in both UIs.
            XCTAssertFalse(def.searchTagsEN.isEmpty, "\(kind.rawValue): missing EN tags")
            XCTAssertFalse(def.searchTagsZH.isEmpty, "\(kind.rawValue): missing ZH tags")
        }
    }
}
