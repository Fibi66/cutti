import XCTest
import CuttiKit
@testable import CuttiMac

final class SubtitleBurnInRendererTests: XCTestCase {

    /// Positioning transform should place the overlay centered horizontally
    /// when `horizontalPositionFraction` is 0.5 and vertically according to
    /// the `verticalPositionFraction`. Core Image Y axis grows upward, so a
    /// fraction of 1 (bottom of the frame) should map to a low Y value.
    func test_positioningTransform_centerAlignment_bottom() {
        let style = SubtitleStyle.default  // hFrac = 0.5, vFrac = 0.88
        let renderer = SubtitleBurnInRenderer(
            cues: [],
            style: style,
            renderSize: CGSize(width: 1920, height: 1080)
        )

        let overlayW: CGFloat = 800
        let overlayH: CGFloat = 100
        let t = renderer.positioningTransform(overlayWidth: overlayW, overlayHeight: overlayH)

        // Centered horizontally: xCenter = 0.5 * 1920 = 960, tx = 960 - 400 = 560
        XCTAssertEqual(t.tx, 560, accuracy: 0.5)

        // Vertical: centerFromTop = 0.88 * 1080 = 950.4
        // centerFromBottom = 1080 - 950.4 = 129.6, ty = 129.6 - 50 = 79.6
        XCTAssertEqual(t.ty, 79.6, accuracy: 0.5)
    }

    func test_positioningTransform_horizontalFraction_movesOverlay() {
        var style = SubtitleStyle.default
        style.horizontalPositionFraction = 0.25
        let renderer = SubtitleBurnInRenderer(cues: [], style: style, renderSize: CGSize(width: 1920, height: 1080))
        let t = renderer.positioningTransform(overlayWidth: 400, overlayHeight: 100)
        // xCenter = 0.25 * 1920 = 480, tx = 480 - 200 = 280
        XCTAssertEqual(t.tx, 280, accuracy: 0.5)
    }

    func test_positioningTransform_topFraction_placesNearTop() {
        var style = SubtitleStyle.default
        style.verticalPositionFraction = 0.1
        let renderer = SubtitleBurnInRenderer(cues: [], style: style, renderSize: CGSize(width: 1920, height: 1080))
        let t = renderer.positioningTransform(overlayWidth: 400, overlayHeight: 100)
        // centerFromTop = 108, centerFromBottom = 972, ty = 922
        XCTAssertEqual(t.ty, 922, accuracy: 0.5)
    }

    func test_cueLookup_returnsActiveCueOnly() {
        let cues: [SubtitleBurnInRenderer.Cue] = [
            .init(startSeconds: 0.0, endSeconds: 1.0, text: "A"),
            .init(startSeconds: 1.0, endSeconds: 2.5, text: "B"),
        ]
        let renderer = SubtitleBurnInRenderer(cues: cues, style: .default, renderSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(renderer.cue(at: 0.5)?.text, "A")
        XCTAssertEqual(renderer.cue(at: 1.0)?.text, "B")
        XCTAssertEqual(renderer.cue(at: 2.4)?.text, "B")
        XCTAssertNil(renderer.cue(at: 2.5))
        XCTAssertNil(renderer.cue(at: 3.0))
    }

    func test_render_producesOverlayImage_whenCueActive() {
        let cues: [SubtitleBurnInRenderer.Cue] = [
            .init(startSeconds: 0, endSeconds: 2, text: "Hello"),
        ]
        let renderer = SubtitleBurnInRenderer(cues: cues, style: .default, renderSize: CGSize(width: 1280, height: 720))
        XCTAssertNotNil(renderer.overlay(at: 1.0))
        XCTAssertNil(renderer.overlay(at: 5.0))
    }

    func test_render_nilForEmptyTextCue() {
        let cues: [SubtitleBurnInRenderer.Cue] = [
            .init(startSeconds: 0, endSeconds: 2, text: "   "),
        ]
        let renderer = SubtitleBurnInRenderer(cues: cues, style: .default, renderSize: CGSize(width: 1280, height: 720))
        XCTAssertNil(renderer.overlay(at: 1.0))
    }

    // MARK: - Per-run rich text

    /// A cue that carries a run-array whose plain text matches `text`
    /// should still produce an overlay (runs are an additive styling
    /// feature — they never blank the cue).
    func test_render_cueWithConsistentRuns_producesOverlay() {
        let runs = [
            SubtitleRun(text: "Hello "),
            SubtitleRun(
                text: "world",
                style: SubtitleRunStyle(
                    sizeMultiplier: 1.4,
                    weight: .bold,
                    textColor: .yellow
                )
            ),
        ]
        let cues: [SubtitleBurnInRenderer.Cue] = [
            .init(startSeconds: 0, endSeconds: 2, text: "Hello world", runs: runs),
        ]
        let renderer = SubtitleBurnInRenderer(
            cues: cues,
            style: .default,
            renderSize: CGSize(width: 1280, height: 720)
        )
        XCTAssertNotNil(renderer.overlay(at: 1.0))
    }

    /// A cue whose `runs` drifted from `text` (plain-text mismatch)
    /// must fall back to uniform styling rather than blanking out —
    /// the renderer is defensive against upstream bugs.
    func test_render_cueWithInconsistentRuns_fallsBackToPlain() {
        let runs = [SubtitleRun(text: "something else")]
        let cues: [SubtitleBurnInRenderer.Cue] = [
            .init(startSeconds: 0, endSeconds: 2, text: "Hello world", runs: runs),
        ]
        let renderer = SubtitleBurnInRenderer(
            cues: cues,
            style: .default,
            renderSize: CGSize(width: 1280, height: 720)
        )
        XCTAssertNotNil(renderer.overlay(at: 1.0))
    }

    /// The attributed string builder should apply per-run overrides on
    /// top of the baseline attributes. Here we verify that a color
    /// override is reflected in the run's `.foregroundColor` attribute.
    func test_makeAttributedString_runOverride_setsForegroundColor() {
        let renderer = SubtitleBurnInRenderer(
            cues: [],
            style: .default,
            renderSize: CGSize(width: 1920, height: 1080)
        )
        let runs = [
            SubtitleRun(text: "ab"),
            SubtitleRun(
                text: "cd",
                style: SubtitleRunStyle(textColor: .yellow)
            ),
        ]
        let attr = renderer.makeAttributedString(
            text: "abcd",
            runs: runs,
            baseFontSize: 48
        )
        XCTAssertEqual(attr.string, "abcd")
        let firstColor = attr.attribute(
            .foregroundColor, at: 0, effectiveRange: nil) as! CGColor
        let secondColor = attr.attribute(
            .foregroundColor, at: 2, effectiveRange: nil) as! CGColor
        // White vs yellow differ in green/blue channels — sufficient for
        // a smoke check without colorspace conversion.
        XCTAssertNotEqual(firstColor, secondColor)
    }

    /// A nil `runs` input must produce a single uniform attribute run —
    /// this is the back-compat path that preserves pre-rich-text
    /// rendering byte-for-byte.
    func test_makeAttributedString_nilRuns_producesUniformAttributes() {
        let renderer = SubtitleBurnInRenderer(
            cues: [],
            style: .default,
            renderSize: CGSize(width: 1920, height: 1080)
        )
        let attr = renderer.makeAttributedString(
            text: "Hello world",
            runs: nil,
            baseFontSize: 48
        )
        var effective = NSRange()
        _ = attr.attribute(.foregroundColor, at: 0, effectiveRange: &effective)
        XCTAssertEqual(effective.length, attr.length)
    }

    /// Runs whose concatenated text doesn't match `text` should also
    /// fall back to uniform attributes (defensive).
    func test_makeAttributedString_driftedRuns_fallBackToUniform() {
        let renderer = SubtitleBurnInRenderer(
            cues: [],
            style: .default,
            renderSize: CGSize(width: 1920, height: 1080)
        )
        let runs = [SubtitleRun(text: "ab"), SubtitleRun(text: "cd")]
        let attr = renderer.makeAttributedString(
            text: "WRONG TEXT",
            runs: runs,
            baseFontSize: 48
        )
        XCTAssertEqual(attr.string, "WRONG TEXT")
        var effective = NSRange()
        _ = attr.attribute(.foregroundColor, at: 0, effectiveRange: &effective)
        XCTAssertEqual(effective.length, attr.length)
    }

    // MARK: Highlight background

    /// A run with `highlightBackground` set should tag the attributed
    /// string with the custom `highlightBGAttrKey` (CGColor value) over
    /// exactly the run's character range. The pill is drawn in a
    /// second pass during CTFrameDraw, so the attribute must survive
    /// onto the finished attributed string.
    func test_makeAttributedString_highlightBackground_tagsCustomKey() {
        let renderer = SubtitleBurnInRenderer(
            cues: [],
            style: .default,
            renderSize: CGSize(width: 1920, height: 1080)
        )
        let runs = [
            SubtitleRun(text: "ab"),
            SubtitleRun(
                text: "cd",
                style: SubtitleRunStyle(
                    highlightBackground: SubtitleStyle.RGBAColor(
                        red: 1, green: 1, blue: 0, alpha: 0.5
                    )
                )
            ),
            SubtitleRun(text: "ef"),
        ]
        let attr = renderer.makeAttributedString(
            text: "abcdef",
            runs: runs,
            baseFontSize: 48
        )

        let key = SubtitleBurnInRenderer.highlightBGAttrKey
        // Unhighlighted runs: no key.
        XCTAssertNil(attr.attribute(key, at: 0, effectiveRange: nil))
        XCTAssertNil(attr.attribute(key, at: 5, effectiveRange: nil))
        // Highlighted run: CGColor value covering exactly indices 2..<4.
        var effective = NSRange()
        let value = attr.attribute(key, at: 2, effectiveRange: &effective)
        XCTAssertNotNil(value)
        XCTAssertEqual(effective.location, 2)
        XCTAssertEqual(effective.length, 2)
        // Round-trip: value should be a CGColor with yellow-ish channels.
        if let cg = value as! CGColor? {
            let components = cg.components ?? []
            XCTAssertGreaterThanOrEqual(components.count, 3)
        } else {
            XCTFail("highlight attribute should be a CGColor")
        }
    }

    /// A run with `highlightBackground` set but zero alpha should NOT
    /// tag the attribute — we treat "transparent highlight" as "no
    /// highlight" so the pill pass skips the draw entirely.
    func test_makeAttributedString_highlightBackground_transparentIsIgnored() {
        let renderer = SubtitleBurnInRenderer(
            cues: [],
            style: .default,
            renderSize: CGSize(width: 1920, height: 1080)
        )
        let runs = [
            SubtitleRun(
                text: "ab",
                style: SubtitleRunStyle(
                    highlightBackground: SubtitleStyle.RGBAColor(
                        red: 1, green: 0, blue: 0, alpha: 0
                    )
                )
            ),
        ]
        let attr = renderer.makeAttributedString(
            text: "ab",
            runs: runs,
            baseFontSize: 48
        )
        let key = SubtitleBurnInRenderer.highlightBGAttrKey
        XCTAssertNil(attr.attribute(key, at: 0, effectiveRange: nil))
    }

    /// End-to-end smoke: rendering a cue that carries a
    /// `highlightBackground` should still produce a valid overlay image
    /// (the second-pass pill draw shouldn't crash on empty layouts,
    /// empty runs, or unusual line breaks).
    func test_render_cueWithHighlightBackground_producesOverlay() {
        let start = SubtitleStyle.RGBAColor(red: 0, green: 1, blue: 0, alpha: 0.4)
        let runs = [
            SubtitleRun(text: "Hello "),
            SubtitleRun(
                text: "world",
                style: SubtitleRunStyle(highlightBackground: start)
            ),
        ]
        let entry = SubtitleEntry(
            id: UUID(),
            relativeStart: 0,
            relativeDuration: 2,
            text: "Hello world",
            runs: runs
        )
        let renderer = SubtitleBurnInRenderer(
            cues: [
                .init(
                    startSeconds: 0,
                    endSeconds: 2,
                    text: entry.text,
                    runs: entry.runs
                )
            ],
            style: .default,
            renderSize: CGSize(width: 1920, height: 1080)
        )
        let image = renderer.render(text: entry.text, runs: entry.runs)
        XCTAssertNotNil(image)
    }
}
