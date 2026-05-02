import AVFoundation
import Foundation
import CuttiKit

enum AppleSiliconProxySettings {
    static let profile: ProxyProfile = .appleSiliconEditingProxy
    static let exportPreset: String = AVAssetExportPresetAppleProRes422LPCM
    static let outputFileType: AVFileType = profile.outputFileType
}
