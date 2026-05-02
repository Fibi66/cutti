import AVFoundation
import XCTest
@testable import CuttiMac

final class AppleSiliconProxySettingsTests: XCTestCase {
    func test_defaultPhaseOneProxy_usesAppleNativeMovOutput() {
        XCTAssertEqual(
            AppleSiliconProxySettings.exportPreset,
            AVAssetExportPresetAppleProRes422LPCM
        )
        XCTAssertEqual(AppleSiliconProxySettings.outputFileType, .mov)
        XCTAssertEqual(AppleSiliconProxySettings.profile.fileExtension, "mov")
    }
}
