import XCTest
import CuttiKit
@testable import CuttiMac

final class SubtitleStyleTests: XCTestCase {

    func test_presets_haveDistinctIDs() {
        let ids = SubtitleStyle.allPresets.compactMap { $0.presetID }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.count, 3)
    }

    func test_preset_lookupByID() {
        XCTAssertEqual(SubtitleStyle.preset(id: SubtitleStyle.defaultPresetID),    .default)
        XCTAssertEqual(SubtitleStyle.preset(id: SubtitleStyle.boldYellowPresetID), .boldYellow)
        XCTAssertEqual(SubtitleStyle.preset(id: SubtitleStyle.minimalPresetID),    .minimal)
        XCTAssertNil(SubtitleStyle.preset(id: "cutti.nonexistent"))
    }

    func test_preset_displayNamesAreHumanReadable() {
        XCTAssertEqual(SubtitleStyle.default.displayName,    "Default")
        XCTAssertEqual(SubtitleStyle.boldYellow.displayName, "Bold Yellow")
        XCTAssertEqual(SubtitleStyle.minimal.displayName,    "Minimal")
        var custom = SubtitleStyle.default
        custom.presetID = nil
        XCTAssertEqual(custom.displayName, "Custom")
    }

    func test_style_codableRoundtrip_preservesAllFields() throws {
        let original = SubtitleStyle.boldYellow
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_subtitleExportOption_sidecarExtension() {
        XCTAssertEqual(SubtitleExportOption.none.sidecarExtension,             nil)
        XCTAssertEqual(SubtitleExportOption.sidecarSRT.sidecarExtension,       "srt")
        XCTAssertEqual(SubtitleExportOption.sidecarVTT.sidecarExtension,       "vtt")
        XCTAssertEqual(SubtitleExportOption.burnIn(.default).sidecarExtension, nil)
    }

    func test_subtitleExportOption_isBurnIn() {
        XCTAssertFalse(SubtitleExportOption.none.isBurnIn)
        XCTAssertFalse(SubtitleExportOption.sidecarSRT.isBurnIn)
        XCTAssertTrue(SubtitleExportOption.burnIn(.default).isBurnIn)
    }
}
