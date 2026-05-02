import AVFoundation
import XCTest
import CuttiKit
@testable import CuttiMac

final class ProxyProfileTests: XCTestCase {
    func test_appleSiliconEditingProxy_usesMovContainer() {
        let mediaID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let profile = ProxyProfile.appleSiliconEditingProxy

        XCTAssertEqual(profile.fileExtension, "mov")
        XCTAssertEqual(profile.outputFileType, .mov)
        XCTAssertEqual(
            profile.relativeProxyPath(for: mediaID),
            "media/proxies/\(mediaID.uuidString).mov"
        )
    }
}
