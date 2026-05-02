import XCTest
import AppKit
import SwiftUI
import CuttiKit
@testable import CuttiMac

@MainActor
final class SubtitleAttributedStringTests: XCTestCase {

    // MARK: - Back-compat paths

    func test_nilRuns_returnsUniformAttributedString() {
        let attr = makeSubtitleAttributedString(
            text: "Hello",
            runs: nil,
            baseFontSize: 40,
            baseColor: .white,
            baseWeight: .bold
        )
        // AttributedString round-trips to NSAttributedString without losing
        // attributes; inspect via that bridge.
        let ns = NSAttributedString(attr)
        XCTAssertEqual(ns.string, "Hello")
        // Every character shares the same base font.
        let full = NSRange(location: 0, length: ns.length)
        var longestRange = NSRange()
        let font = ns.attribute(.font, at: 0, longestEffectiveRange: &longestRange,
                                in: full) as? NSFont
        XCTAssertEqual(longestRange, full, "nil runs must produce a uniform attribute span")
        XCTAssertEqual(font?.pointSize, 40)
    }

    func test_emptyRunsArray_returnsUniformAttributedString() {
        let attr = makeSubtitleAttributedString(
            text: "Hello",
            runs: [],
            baseFontSize: 40,
            baseColor: .white,
            baseWeight: .bold
        )
        let ns = NSAttributedString(attr)
        XCTAssertEqual(ns.string, "Hello")
    }

    func test_driftedRuns_fallBackToUniform() {
        // runs.plainText = "Helxo" ≠ "Hello"; renderer must degrade, not crash.
        let drifted = [
            SubtitleRun(text: "Hel"),
            SubtitleRun(text: "xo", style: SubtitleRunStyle(
                textColor: .init(red: 1, green: 0, blue: 0, alpha: 1)
            )),
        ]
        let attr = makeSubtitleAttributedString(
            text: "Hello",
            runs: drifted,
            baseFontSize: 32,
            baseColor: .white,
            baseWeight: .bold
        )
        let ns = NSAttributedString(attr)
        XCTAssertEqual(ns.string, "Hello")
        // Uniform foreground (no drift-through).
        var longestRange = NSRange()
        _ = ns.attribute(.foregroundColor, at: 0,
                         longestEffectiveRange: &longestRange,
                         in: NSRange(location: 0, length: ns.length))
        XCTAssertEqual(longestRange.length, ns.length)
    }

    // MARK: - Per-run overrides

    func test_runColorOverride_appliesToRange() {
        let runs = [
            SubtitleRun(text: "Hel"),
            SubtitleRun(text: "lo", style: SubtitleRunStyle(
                textColor: .init(red: 1, green: 0, blue: 0, alpha: 1)
            )),
        ]
        let attr = makeSubtitleAttributedString(
            text: "Hello",
            runs: runs,
            baseFontSize: 32,
            baseColor: .white,
            baseWeight: .bold
        )
        let ns = NSAttributedString(attr)
        let overridden = ns.attribute(.foregroundColor, at: 3, effectiveRange: nil)
            as? NSColor
        XCTAssertNotNil(overridden)
        let rgb = overridden?.usingColorSpace(.sRGB)
        XCTAssertEqual(rgb?.redComponent ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(rgb?.greenComponent ?? 1, 0.0, accuracy: 0.01)
    }

    func test_runSizeMultiplier_inflatesFont() {
        let runs = [
            SubtitleRun(text: "small "),
            SubtitleRun(text: "BIG", style: SubtitleRunStyle(sizeMultiplier: 2.0)),
        ]
        let attr = makeSubtitleAttributedString(
            text: "small BIG",
            runs: runs,
            baseFontSize: 30,
            baseColor: .white,
            baseWeight: .bold
        )
        let ns = NSAttributedString(attr)
        let baseFont = ns.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        // "BIG" starts at utf16 offset 6.
        let bigFont = ns.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        XCTAssertEqual(baseFont?.pointSize, 30)
        XCTAssertEqual(bigFont?.pointSize, 60)
    }

    func test_runUnderline_addsAttribute() {
        let runs = [
            SubtitleRun(text: "not "),
            SubtitleRun(text: "here", style: SubtitleRunStyle(underline: true)),
        ]
        let attr = makeSubtitleAttributedString(
            text: "not here",
            runs: runs,
            baseFontSize: 20,
            baseColor: .white,
            baseWeight: .bold
        )
        let ns = NSAttributedString(attr)
        XCTAssertNil(ns.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        let style = ns.attribute(.underlineStyle, at: 4, effectiveRange: nil) as? Int
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue)
    }

    func test_chineseText_utf16OffsetsSliceCorrectly() {
        // BMP CJK codepoints are 1 UTF-16 unit each, same as SubtitleRunEditor.
        let runs = [
            SubtitleRun(text: "你好"),
            SubtitleRun(text: "世界", style: SubtitleRunStyle(
                textColor: .init(red: 1, green: 0.5, blue: 0, alpha: 1)
            )),
        ]
        let attr = makeSubtitleAttributedString(
            text: "你好世界",
            runs: runs,
            baseFontSize: 24,
            baseColor: .white,
            baseWeight: .bold
        )
        let ns = NSAttributedString(attr)
        XCTAssertEqual(ns.length, 4)
        let first = ns.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let last = ns.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        // First half keeps the baseline; second half gets the override.
        XCTAssertNotNil(first)
        XCTAssertNotNil(last)
        let lastRGB = last?.usingColorSpace(.sRGB)
        XCTAssertEqual(lastRGB?.redComponent ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(lastRGB?.greenComponent ?? 0, 0.5, accuracy: 0.01)
    }

    func test_emptyStyleRun_inheritsBaseline() {
        let runs = [
            SubtitleRun(text: "a"),
            SubtitleRun(text: "b"),
        ]
        let attr = makeSubtitleAttributedString(
            text: "ab",
            runs: runs,
            baseFontSize: 20,
            baseColor: .white,
            baseWeight: .bold
        )
        let ns = NSAttributedString(attr)
        var longestRange = NSRange()
        _ = ns.attribute(.font, at: 0, longestEffectiveRange: &longestRange,
                         in: NSRange(location: 0, length: ns.length))
        // Runs with empty style shouldn't fragment the attribute span.
        XCTAssertEqual(longestRange.length, ns.length)
    }
}
