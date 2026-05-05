import XCTest
@testable import CuttiKit

final class SubtitleCueStyleOverrideTests: XCTestCase {

    private let base = SubtitleStyle.default

    // MARK: - applied(to:)

    func test_applied_emptyOverride_returnsBaseUnchanged() {
        let empty = SubtitleCueStyleOverride()
        XCTAssertEqual(empty.applied(to: base), base)
    }

    func test_applied_singleField_overridesOnlyThatField() {
        let override = SubtitleCueStyleOverride(fontSizePoints: 80)
        let result = override.applied(to: base)
        XCTAssertEqual(result.fontSizePoints, 80)
        // Unchanged fields preserved.
        XCTAssertEqual(result.fontName, base.fontName)
        XCTAssertEqual(result.textColor, base.textColor)
        XCTAssertEqual(result.backgroundColor, base.backgroundColor)
    }

    func test_applied_clampsFontSize_lowerBound() {
        let override = SubtitleCueStyleOverride(fontSizePoints: 1)
        XCTAssertEqual(override.applied(to: base).fontSizePoints, 12)
    }

    func test_applied_clampsFontSize_upperBound() {
        let override = SubtitleCueStyleOverride(fontSizePoints: 1000)
        XCTAssertEqual(override.applied(to: base).fontSizePoints, 200)
    }

    func test_applied_clampsVerticalPosition() {
        XCTAssertEqual(SubtitleCueStyleOverride(verticalPositionFraction: -0.5).applied(to: base).verticalPositionFraction, 0)
        XCTAssertEqual(SubtitleCueStyleOverride(verticalPositionFraction: 1.5).applied(to: base).verticalPositionFraction, 1)
    }

    func test_applied_clampsMaxWidth() {
        XCTAssertEqual(SubtitleCueStyleOverride(maxWidthFraction: 0.05).applied(to: base).maxWidthFraction, 0.1)
        XCTAssertEqual(SubtitleCueStyleOverride(maxWidthFraction: 2.0).applied(to: base).maxWidthFraction, 1.0)
    }

    func test_applied_emptyFontName_isIgnored() {
        // Mirrors SubtitleStylePatch.applyReporting so an empty
        // string from a buggy caller doesn't blank the font.
        let override = SubtitleCueStyleOverride(fontName: "")
        XCTAssertEqual(override.applied(to: base).fontName, base.fontName)
    }

    func test_applied_doesNotTouchBilingual() {
        // Build a base with bilingual on; override should leave it alone.
        var withBilingual = base
        withBilingual.bilingual = BilingualDisplayOptions(
            primaryLocale: "en-US",
            secondaryLocale: "zh-Hans",
            secondarySizeRatio: 0.7,
            lineSpacingFraction: 0.2,
            placement: .below
        )
        let override = SubtitleCueStyleOverride(fontSizePoints: 60, textColor: .yellow)
        let result = override.applied(to: withBilingual)
        XCTAssertEqual(result.bilingual, withBilingual.bilingual)
        XCTAssertEqual(result.fontSizePoints, 60)
        XCTAssertEqual(result.textColor, .yellow)
    }

    // MARK: - merging

    func test_merging_otherWinsForNonNilFields() {
        let lhs = SubtitleCueStyleOverride(fontSizePoints: 50, textColor: .yellow)
        let rhs = SubtitleCueStyleOverride(fontSizePoints: 80, backgroundColor: .black)
        let merged = lhs.merging(rhs)
        XCTAssertEqual(merged.fontSizePoints, 80, "rhs wins for fontSize")
        XCTAssertEqual(merged.textColor, .yellow, "lhs preserved when rhs nil")
        XCTAssertEqual(merged.backgroundColor, .black, "rhs new field added")
    }

    func test_merging_nilOtherIsIdentity() {
        let lhs = SubtitleCueStyleOverride(fontSizePoints: 50, textColor: .yellow)
        XCTAssertEqual(lhs.merging(SubtitleCueStyleOverride()), lhs)
    }

    func test_merging_isAssociativeForFieldLevel() {
        let a = SubtitleCueStyleOverride(fontSizePoints: 40)
        let b = SubtitleCueStyleOverride(textColor: .yellow)
        let c = SubtitleCueStyleOverride(backgroundColor: .black)
        XCTAssertEqual(a.merging(b).merging(c), a.merging(b.merging(c)))
    }

    // MARK: - hasAnyField

    func test_hasAnyField_emptyIsFalse() {
        XCTAssertFalse(SubtitleCueStyleOverride().hasAnyField)
    }

    func test_hasAnyField_anyNonNilIsTrue() {
        XCTAssertTrue(SubtitleCueStyleOverride(fontSizePoints: 50).hasAnyField)
        XCTAssertTrue(SubtitleCueStyleOverride(alignment: .leading).hasAnyField)
        XCTAssertTrue(SubtitleCueStyleOverride(shadowOffsetY: 0).hasAnyField,
                      "Setting a numeric to 0 still counts — it's still an override.")
    }

    // MARK: - diff

    func test_diff_capturesOnlyChangedFields() {
        var modified = base
        modified.fontSizePoints = 90
        modified.textColor = .yellow
        let diff = SubtitleCueStyleOverride.diff(effective: modified, base: base)
        XCTAssertEqual(diff.fontSizePoints, 90)
        XCTAssertEqual(diff.textColor, .yellow)
        XCTAssertNil(diff.fontName, "Unchanged fields stay nil")
        XCTAssertNil(diff.backgroundColor)
    }

    func test_diff_identicalStylesYieldsEmpty() {
        XCTAssertFalse(SubtitleCueStyleOverride.diff(effective: base, base: base).hasAnyField)
    }

    func test_diff_roundtripsThroughApplied() {
        var modified = base
        modified.fontSizePoints = 55
        modified.alignment = .leading
        modified.maxWidthFraction = 0.6
        let diff = SubtitleCueStyleOverride.diff(effective: modified, base: base)
        XCTAssertEqual(diff.applied(to: base), modified,
                       "diff(modified, base).applied(base) should == modified")
    }

    // MARK: - Codable round-trip

    func test_codable_roundTrip() throws {
        let override = SubtitleCueStyleOverride(
            fontSizePoints: 64,
            textColor: .yellow,
            backgroundColor: SubtitleStyle.RGBAColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 0.8),
            verticalPositionFraction: 0.7,
            alignment: .leading,
            maxWidthFraction: 0.7
        )
        let encoded = try JSONEncoder().encode(override)
        let decoded = try JSONDecoder().decode(SubtitleCueStyleOverride.self, from: encoded)
        XCTAssertEqual(decoded, override)
    }

    func test_codable_decodesEmptyJSONAsAllNil() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SubtitleCueStyleOverride.self, from: json)
        XCTAssertFalse(decoded.hasAnyField)
    }

    func test_codable_decodesPartialJSON() throws {
        let json = #"{"fontSizePoints": 72}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SubtitleCueStyleOverride.self, from: json)
        XCTAssertEqual(decoded.fontSizePoints, 72)
        XCTAssertNil(decoded.textColor)
        XCTAssertTrue(decoded.hasAnyField)
    }
}
