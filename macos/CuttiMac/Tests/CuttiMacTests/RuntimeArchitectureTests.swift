import XCTest
@testable import CuttiMac

final class RuntimeArchitectureTests: XCTestCase {
    func test_warningMessage_isNil_forNativeAppleSilicon() {
        let runtime = RuntimeArchitecture(machineIdentifier: "arm64", isTranslated: false)

        XCTAssertTrue(runtime.isNativeAppleSilicon)
        XCTAssertNil(runtime.warningMessage)
    }

    func test_warningMessage_exists_forTranslatedRuntime() {
        let runtime = RuntimeArchitecture(machineIdentifier: "arm64", isTranslated: true)

        XCTAssertFalse(runtime.isNativeAppleSilicon)
        XCTAssertEqual(
            runtime.warningMessage,
            "Cutti expects native Apple Silicon. Current runtime is not native arm64."
        )
    }

    func test_warningMessage_exists_forIntelNativeRuntime() {
        let runtime = RuntimeArchitecture(machineIdentifier: "x86_64", isTranslated: false)

        XCTAssertFalse(runtime.isNativeAppleSilicon)
        XCTAssertEqual(
            runtime.warningMessage,
            "Cutti expects native Apple Silicon. Current runtime is not native arm64."
        )
    }

    // Covers the readMachineIdentifier() fallback: "unknown" is treated as non-arm64,
    // triggering the warning rather than silently succeeding.
    func test_warningMessage_exists_forUnknownMachineIdentifier() {
        let runtime = RuntimeArchitecture(machineIdentifier: "unknown", isTranslated: false)

        XCTAssertFalse(runtime.isNativeAppleSilicon)
        XCTAssertNotNil(runtime.warningMessage)
    }

    // Smoke test: the live sysctlbyname path returns a non-empty identifier.
    func test_current_returnsNonEmptyMachineIdentifier() {
        let runtime = RuntimeArchitecture.current()
        XCTAssertFalse(runtime.machineIdentifier.isEmpty)
    }
}
