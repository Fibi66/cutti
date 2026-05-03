import XCTest
import CuttiKit
@testable import CuttiMac

// MARK: - Fake renderer

/// In-memory stand-in for `LocalRemotionRenderer`. Records calls and
/// writes a tiny placeholder file at the requested URL so that the
/// downstream importer has something real to ingest.
final class FakeRemotionRenderer: RemotionOverlayRendering, @unchecked Sendable {
    var recordedRequests: [RemotionRenderRequest] = []
    var recordedOutputURLs: [URL] = []
    var stubbedError: (any Error)?

    func render(_ request: RemotionRenderRequest, outputURL: URL) async throws {
        recordedRequests.append(request)
        recordedOutputURLs.append(outputURL)
        if let stubbedError {
            throw stubbedError
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Minimal payload — the importer fingerprints bytes but doesn't
        // decode, so any non-empty file is enough for tests.
        try Data("fake-prores-4444".utf8).write(to: outputURL)
    }
}

// MARK: - Argument building

final class RemotionRenderServiceArgsTests: XCTestCase {
    func test_makeArguments_forcesAlphaCapableCodec() {
        let request = RemotionRenderRequest(
            templateID: "ChapterTitle",
            propsJSON: #"{"title":"Hello"}"#,
            durationSeconds: 2.5
        )
        let out = URL(fileURLWithPath: "/tmp/out.mov")

        let args = LocalRemotionRenderer.makeArguments(request: request, outputURL: out)

        XCTAssertEqual(args.first, "npx")
        XCTAssertTrue(args.contains("remotion"))
        XCTAssertTrue(args.contains("render"))
        XCTAssertTrue(args.contains("ChapterTitle"))
        XCTAssertTrue(args.contains("/tmp/out.mov"))
        XCTAssertTrue(args.contains("--codec=prores"),
                      "overlay track requires alpha; ProRes is the only codec we ship that keeps it")
        XCTAssertTrue(args.contains("--prores-profile=4444"))
        XCTAssertTrue(args.contains(#"--props={"title":"Hello"}"#))
    }

    func test_render_throwsWhenProjectDirectoryMissing() async {
        let renderer = LocalRemotionRenderer(
            projectDirectory: URL(fileURLWithPath: "/nonexistent/remotion-project-\(UUID().uuidString)")
        )
        let request = RemotionRenderRequest(
            templateID: "ChapterTitle",
            propsJSON: "{}",
            durationSeconds: 2.0
        )

        do {
            try await renderer.render(request, outputURL: URL(fileURLWithPath: "/tmp/x.mov"))
            XCTFail("expected projectDirectoryMissing")
        } catch let error as RemotionRenderError {
            if case .projectDirectoryMissing = error {
                return
            }
            XCTFail("unexpected error: \(error)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

// MARK: - ViewModel integration

@MainActor
final class MediaCoreViewModelOverlayGenerationTests: XCTestCase {
    private func makeTempProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cutti-overlay-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func test_generateOverlay_rendersImportsAndInsertsOnOverlayTrack() async throws {
        let root = try makeTempProjectRoot()
        let store = ProjectStore(projectRoot: root)
        try store.bootstrapProject()

        let importedID = UUID()
        let stubMediaCore = StubMediaCore()
        stubMediaCore.importResult = .success(importedID)

        let renderer = FakeRemotionRenderer()

        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: root,
            overlayRenderer: renderer
        )

        // Seed the primary track + a matching media record so the overlay
        // has a timeline to land on. loadRecords() inside generateOverlay
        // will pick up the imported asset from the manifest, but we also
        // need the primary asset recorded so the overlay's composed time
        // maps to something real.
        var manifest = try store.loadManifest()
        let primaryAsset = MediaAssetRecord(
            id: UUID(),
            sourcePath: "/tmp/primary.mov",
            fingerprint: SourceFingerprint(fileSize: 10, modifiedAt: Date(), sha256Prefix: "p"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 20, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: "media/proxies/primary.mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        let overlayAsset = MediaAssetRecord(
            id: importedID,
            sourcePath: "/tmp/overlay.mov",
            fingerprint: SourceFingerprint(fileSize: 10, modifiedAt: Date(), sha256Prefix: "o"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 2.5, width: 1920, height: 1080, nominalFPS: 30, hasAudio: false),
            derived: DerivedAssetState(proxyRelativePath: "media/proxies/overlay.mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        manifest.media = [primaryAsset, overlayAsset]
        try store.saveManifest(manifest)

        vm.records = [primaryAsset]
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: primaryAsset.id,
                range: TimeRange(startSeconds: 0, endSeconds: 20),
                text: "",
                subtitles: []
            )
        ]

        await vm.generateOverlay(
            templateID: "ChapterTitle",
            propsJSON: #"{"title":"Hello","durationSeconds":2.5}"#,
            durationSeconds: 2.5,
            at: 5.0
        )

        // Renderer called exactly once, with the forwarded fields.
        XCTAssertEqual(renderer.recordedRequests.count, 1)
        XCTAssertEqual(renderer.recordedRequests.first?.templateID, "ChapterTitle")
        XCTAssertEqual(renderer.recordedRequests.first?.durationSeconds, 2.5)

        // Output lives under the project's media/overlays scratch dir.
        let output = try XCTUnwrap(renderer.recordedOutputURLs.first)
        XCTAssertTrue(output.path.contains("media/overlays/"),
                      "overlays must land in the project scratch dir, got \(output.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        // Import was invoked on exactly that URL.
        XCTAssertEqual(stubMediaCore.importedURLs, [output])

        // Overlay track now carries a segment referencing the imported asset.
        let overlaySegments = vm.project.overlayTracks.flatMap(\.segments)
        XCTAssertEqual(overlaySegments.count, 1)
        XCTAssertEqual(overlaySegments.first?.sourceVideoID, importedID)

        // Banner is cleared on success.
        XCTAssertNil(vm.bannerMessage)

        try? FileManager.default.removeItem(at: root)
    }

    func test_generateOverlay_missingRenderer_setsBannerAndIsNoOp() async throws {
        let root = try makeTempProjectRoot()
        let store = ProjectStore(projectRoot: root)
        try store.bootstrapProject()

        let stubMediaCore = StubMediaCore()
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: root,
            overlayRenderer: nil
        )

        await vm.generateOverlay(
            templateID: "ChapterTitle",
            propsJSON: "{}",
            durationSeconds: 2.0,
            at: 0
        )

        XCTAssertEqual(stubMediaCore.importedURLs, [],
                       "import must not run when no renderer is configured")
        XCTAssertEqual(vm.project.overlayTracks.flatMap(\.segments).count, 0)
        XCTAssertNotNil(vm.bannerMessage)

        try? FileManager.default.removeItem(at: root)
    }

    func test_generateOverlay_rendererFailure_skipsImportAndSurfacesError() async throws {
        let root = try makeTempProjectRoot()
        let store = ProjectStore(projectRoot: root)
        try store.bootstrapProject()

        let stubMediaCore = StubMediaCore()
        let renderer = FakeRemotionRenderer()
        renderer.stubbedError = RemotionRenderError.renderFailed(exitCode: 1, stderr: "boom")

        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: root,
            overlayRenderer: renderer
        )

        let err = await vm.generateOverlay(
            templateID: "ChapterTitle",
            propsJSON: "{}",
            durationSeconds: 2.0,
            at: 0
        )

        XCTAssertEqual(stubMediaCore.importedURLs, [],
                       "render failure must short-circuit before importing")
        XCTAssertEqual(vm.project.overlayTracks.flatMap(\.segments).count, 0)
        XCTAssertNotNil(err, "renderer failure must be returned to the caller")

        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - BYOK live-switch coverage

/// Regression coverage for "user subscribed earlier, switched to BYOK
/// in Settings". The factory fix in
/// `AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer` only protects
/// *new* view models — already-open editors capture their renderer at
/// construction. So `MediaCoreViewModel.makeOverlayCache()` carries a
/// second BYOK gate that fires regardless of how the renderer was
/// wired. These tests pin that gate.
///
/// Mutates `UserDefaults.standard["cutti.aiProvider"]` to flip the
/// provider; setUp/tearDown stash and restore the prior value so a
/// crash mid-test can't poison the dev keychain.
@MainActor
final class MediaCoreViewModelOverlayBYOKTests: XCTestCase {
    private let providerKey = "cutti.aiProvider"
    private var savedProviderRaw: String?

    override func setUp() {
        super.setUp()
        savedProviderRaw = UserDefaults.standard.string(forKey: providerKey)
    }

    override func tearDown() {
        if let saved = savedProviderRaw {
            UserDefaults.standard.set(saved, forKey: providerKey)
        } else {
            UserDefaults.standard.removeObject(forKey: providerKey)
        }
        super.tearDown()
    }

    private func makeTempProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cutti-overlay-byok-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func test_byokProvider_blocksGenerateOverlay_evenWithRendererWired() async throws {
        // The dangerous case: VM was constructed when the user was on
        // `.cuttiCloud`, so it has a real (here, fake) renderer.
        // User then switches to `.custom` in Settings. The next
        // Generate Animation click must NOT reach the renderer — it
        // must surface the BYOK banner instead.
        let root = try makeTempProjectRoot()
        let store = ProjectStore(projectRoot: root)
        try store.bootstrapProject()

        let stubMediaCore = StubMediaCore()
        let renderer = FakeRemotionRenderer()
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: root,
            overlayRenderer: renderer
        )

        UserDefaults.standard.set(
            AIProviderPreference.custom.rawValue,
            forKey: providerKey
        )

        let err = await vm.generateOverlay(
            templateID: "ChapterTitle",
            propsJSON: "{}",
            durationSeconds: 2.0,
            at: 0
        )

        XCTAssertEqual(renderer.recordedRequests, [],
                       "BYOK must never reach the renderer, even one wired at VM construction.")
        XCTAssertEqual(stubMediaCore.importedURLs, [],
                       "BYOK must not import a rendered overlay (because nothing was rendered).")
        XCTAssertEqual(vm.project.overlayTracks.flatMap(\.segments).count, 0)
        XCTAssertNotNil(err, "BYOK gate must surface an error to the caller.")
        XCTAssertEqual(
            vm.bannerMessage,
            L("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud."),
            "BYOK gate must surface the same warning copy used in the AI Provider settings."
        )

        try? FileManager.default.removeItem(at: root)
    }

    func test_byokProvider_clearsStaleOverlayCache() async throws {
        // Second-order leak path: a previous Generate Animation in the
        // same session built `_overlayRenderCache`, memoized inside the
        // VM. Switching to BYOK and clicking again must not reuse it.
        let root = try makeTempProjectRoot()
        let store = ProjectStore(projectRoot: root)
        try store.bootstrapProject()

        let importedID = UUID()
        let stubMediaCore = StubMediaCore()
        stubMediaCore.importResult = .success(importedID)

        let renderer = FakeRemotionRenderer()
        let vm = MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: root,
            overlayRenderer: renderer
        )

        // Seed minimum manifest + timeline so the FIRST generateOverlay
        // succeeds end-to-end and populates the cache.
        var manifest = try store.loadManifest()
        let primaryAsset = MediaAssetRecord(
            id: UUID(),
            sourcePath: "/tmp/primary.mov",
            fingerprint: SourceFingerprint(fileSize: 10, modifiedAt: Date(), sha256Prefix: "p"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 20, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: "media/proxies/primary.mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        let overlayAsset = MediaAssetRecord(
            id: importedID,
            sourcePath: "/tmp/overlay.mov",
            fingerprint: SourceFingerprint(fileSize: 10, modifiedAt: Date(), sha256Prefix: "o"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 2.0, width: 1920, height: 1080, nominalFPS: 30, hasAudio: false),
            derived: DerivedAssetState(proxyRelativePath: "media/proxies/overlay.mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        manifest.media = [primaryAsset, overlayAsset]
        try store.saveManifest(manifest)
        vm.records = [primaryAsset]
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: primaryAsset.id,
                range: TimeRange(startSeconds: 0, endSeconds: 20),
                text: "",
                subtitles: []
            )
        ]

        // First call (cuttiCloud) — populates the cache.
        UserDefaults.standard.set(
            AIProviderPreference.cuttiCloud.rawValue,
            forKey: providerKey
        )
        await vm.generateOverlay(
            templateID: "ChapterTitle",
            propsJSON: #"{"title":"Hello","durationSeconds":2.0}"#,
            durationSeconds: 2.0,
            at: 5.0
        )
        XCTAssertEqual(renderer.recordedRequests.count, 1,
                       "First call under cuttiCloud should render normally.")

        // Switch to BYOK; a second call must not reach the renderer
        // even though the cache is warm.
        UserDefaults.standard.set(
            AIProviderPreference.custom.rawValue,
            forKey: providerKey
        )
        let err = await vm.generateOverlay(
            templateID: "ChapterTitle",
            propsJSON: #"{"title":"World","durationSeconds":2.0}"#,
            durationSeconds: 2.0,
            at: 10.0
        )
        XCTAssertEqual(renderer.recordedRequests.count, 1,
                       "Switching to BYOK must invalidate the warm cache and block the next render.")
        XCTAssertNotNil(err)
        XCTAssertEqual(
            vm.bannerMessage,
            L("⚠️ Animated overlay rendering (chapter cards, animated subtitles) is only available with Cutti Cloud.")
        )

        try? FileManager.default.removeItem(at: root)
    }
}
