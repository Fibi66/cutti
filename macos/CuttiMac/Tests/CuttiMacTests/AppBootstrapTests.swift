import XCTest
@testable import CuttiMac

final class AppBootstrapTests: XCTestCase {
    func test_makeDefaultProjectRoot_pointsIntoApplicationSupport() throws {
        let root = AppEnvironment.makeDefaultProjectRoot(fileManager: .default)
        XCTAssertEqual(root.lastPathComponent, "cutti")
        XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "Application Support")
    }
}
