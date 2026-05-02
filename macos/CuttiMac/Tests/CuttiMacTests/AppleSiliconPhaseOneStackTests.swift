import XCTest
@testable import CuttiMac

final class AppleSiliconPhaseOneStackTests: XCTestCase {

    // MARK: - Helpers

    private func makeTemporaryProjectRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "CuttiMacTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    // MARK: - Tests

    /// `make` must bootstrap the project directory layout (media/, logs/) so that
    /// callers do not need to call `store.bootstrapProject()` separately.
    func test_make_bootstrapsProjectDirectories() throws {
        let projectRoot = makeTemporaryProjectRoot()
        _ = try AppleSiliconPhaseOneStack.make(projectRoot: projectRoot)

        let fm = FileManager.default
        XCTAssertTrue(
            fm.fileExists(atPath: projectRoot.appending(path: "media/proxies").path),
            "make() must create media/proxies directory"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: projectRoot.appending(path: "media/thumbnails").path),
            "make() must create media/thumbnails directory"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: projectRoot.appending(path: "media/waveforms").path),
            "make() must create media/waveforms directory"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: projectRoot.appending(path: "logs").path),
            "make() must create logs directory"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: projectRoot.appending(path: "media/manifest.json").path),
            "make() must create an initial manifest.json"
        )
    }


    /// all proxy writes are MOV-based and leverage Apple-native hardware codecs.
    func test_make_usesAppleSiliconEditingProxyProfile() throws {
        let projectRoot = makeTemporaryProjectRoot()
        let stack = try AppleSiliconPhaseOneStack.make(projectRoot: projectRoot)

        XCTAssertEqual(
            stack.proxyProfile,
            .appleSiliconEditingProxy,
            "Phase 1 stack must use the Apple Silicon Editing Proxy profile"
        )
    }

    /// When the runtime is not native Apple Silicon, the stack must preserve the
    /// warning so the call site (app entry point) can surface it to the user/log.
    func test_make_preservesRuntimeWarning_forNonNativeRuntime() throws {
        let projectRoot = makeTemporaryProjectRoot()
        let nonNativeRuntime = RuntimeArchitecture(machineIdentifier: "x86_64", isTranslated: false)

        let stack = try AppleSiliconPhaseOneStack.make(
            projectRoot: projectRoot,
            runtimeArchitecture: nonNativeRuntime
        )

        XCTAssertNotNil(
            stack.runtimeArchitecture.warningMessage,
            "Stack must preserve the runtime warning for non-native-arm64 environments"
        )
        XCTAssertFalse(
            stack.runtimeArchitecture.isNativeAppleSilicon,
            "x86_64 runtime must not be reported as native Apple Silicon"
        )
    }
}
