import AVFoundation
import Foundation

public struct ProxyProfile: Equatable, Sendable {
    public let fileExtension: String
    public let outputFileType: AVFileType
    public let displayName: String

    public static let appleSiliconEditingProxy = ProxyProfile(
        fileExtension: "mov",
        outputFileType: .mov,
        displayName: "Apple Silicon Editing Proxy"
    )

    public func relativeProxyPath(for mediaId: UUID) -> String {
        "media/proxies/\(mediaId.uuidString).\(fileExtension)"
    }
    public init(
        fileExtension: String,
        outputFileType: AVFileType,
        displayName: String
    ) {
        self.fileExtension = fileExtension
        self.outputFileType = outputFileType
        self.displayName = displayName
    }

}
