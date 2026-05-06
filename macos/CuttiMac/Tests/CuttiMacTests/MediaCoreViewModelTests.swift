import AppKit
import XCTest
import AVFoundation
import CuttiKit
@testable import CuttiMac

// MARK: - Test Spy

/// Spy for PlaybackProviding that captures makePlayer and prepare calls.
final class SpyPlaybackCore: PlaybackProviding {
    var capturedProxyURLs: [URL] = []
    var preparedProxyURLBatches: [[URL]] = []

    func makePlayer(proxyURL: URL) -> AVPlayer {
        capturedProxyURLs.append(proxyURL)
        return AVPlayer()
    }

    func prepare(proxyURLs: [URL]) {
        preparedProxyURLBatches.append(proxyURLs)
    }
}

// MARK: - Test Doubles for MediaCore

final class StubMediaCore: MediaCoreImporting, @unchecked Sendable {
    var importResult: Result<UUID, Error>?
    var importedURLs: [URL] = []
    var relinkHandler: ((UUID, URL) throws -> Void)?
    var validateSourcesHandler: (() throws -> Void)?
    
    func importLocalVideo(
        url: URL,
        progress: @Sendable @escaping (ImportPhase, Double) -> Void
    ) async throws -> UUID {
        importedURLs.append(url)
        guard let result = importResult else {
            fatalError("StubMediaCore.importResult not configured")
        }
        return try result.get()
    }

    func importLocalImage(url: URL) async throws -> UUID {
        importedURLs.append(url)
        guard let result = importResult else {
            fatalError("StubMediaCore.importResult not configured")
        }
        return try result.get()
    }
    
    func relinkOriginal(mediaId: UUID, newURL: URL) throws {
        try relinkHandler?(mediaId, newURL)
    }
    
    func validateSources() throws {
        try validateSourcesHandler?()
    }
}

private struct StubAnalyzer: AssetAnalyzing {
    let summary: AnalysisSummary
    func analyze(url: URL) async throws -> AnalysisSummary { summary }
}

private struct StubTranscoder: ProxyTranscoding {
    let result: TranscodeResult
    func transcode(
        sourceURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> TranscodeResult {
        result
    }
}

// MARK: - Tests

@MainActor
final class MediaCoreViewModelTests: XCTestCase {
    private func makeRecord(
        id: UUID = UUID(),
        status: MediaStatus = .ready,
        proxyRelativePath: String? = "media/proxies/sample.mov",
        errorMessage: String? = nil
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: id,
            sourcePath: "/tmp/\(id.uuidString).mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc"),
            status: status,
            analysis: AnalysisSummary(durationSeconds: 300, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(
                proxyRelativePath: proxyRelativePath,
                thumbnailsReady: false,
                waveformsReady: false
            ),
            errorMessage: errorMessage,
            usedFallbackTranscoder: false
        )
    }

    
    // MARK: - Initial state
    
    func test_init_startsWithNilPlayer() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy)
        XCTAssertNil(vm.player)
    }
    
    func test_init_startsWithNilBannerMessage() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy)
        XCTAssertNil(vm.bannerMessage)
    }

    // MARK: - Player replacement hygiene

    func test_replacingPlayer_pausesOutgoingPlayer() {
        // Regression: when the AI pipeline rebuilds the composition
        // mid-playback, the outgoing AVPlayer must stop. Otherwise it
        // keeps holding an audio/video session while the new player
        // loads the updated asset, and the user hears old audio
        // underneath the new preview.
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy)

        let oldPlayer = AVPlayer()
        vm.player = oldPlayer
        oldPlayer.rate = 1.0
        XCTAssertGreaterThan(oldPlayer.rate, 0, "sanity: player must be playing before swap")

        vm.player = AVPlayer()
        XCTAssertEqual(oldPlayer.rate, 0,
                       "outgoing player must be paused when `player` is reassigned")
    }

    func test_clearingPlayer_pausesOutgoingPlayer() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy)

        let oldPlayer = AVPlayer()
        vm.player = oldPlayer
        oldPlayer.rate = 1.0

        vm.player = nil
        XCTAssertEqual(oldPlayer.rate, 0,
                       "outgoing player must be paused when `player` is cleared")
    }

    // MARK: - Selection with ready record + proxy
    
    func test_select_withReadyRecordAndProxy_createsPlayerViaPlaybackCore() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)

        let record = makeRecord(proxyRelativePath: "proxies/test.mov")
        vm.records = [record]

        vm.select(recordID: record.id)
        
        // Should create player
        XCTAssertNotNil(vm.player)
        XCTAssertNil(vm.bannerMessage)
        
        // Should have called makePlayer with correct URL
        XCTAssertEqual(spy.capturedProxyURLs.count, 1)
        XCTAssertEqual(spy.capturedProxyURLs.first?.path, "/project/proxies/test.mov")
    }

    func test_select_withReadyRecordAndProxyWithoutProjectRoot_keepsMessageSelectionLocal() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy)

        let record = makeRecord(proxyRelativePath: "proxies/test.mov")
        vm.records = [record]

        vm.select(recordID: record.id)

        XCTAssertNil(vm.player)
        XCTAssertEqual(vm.selectedRecordMessage, "Project root not configured")
        XCTAssertNil(vm.bannerMessage)
        XCTAssertEqual(spy.capturedProxyURLs.count, 0)
    }

    // MARK: - Selection with ready record but no proxy
    
    func test_select_withReadyRecordButNoProxy_clearsPlayerAndSetsBanner() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)

        let record = makeRecord(proxyRelativePath: nil)
        vm.records = [record]

        vm.select(recordID: record.id)

        XCTAssertNil(vm.player)
        XCTAssertNil(vm.bannerMessage)
        XCTAssertEqual(vm.selectedRecordMessage, "Media is not ready for preview.")
        XCTAssertEqual(spy.capturedProxyURLs.count, 0)
    }
    
    // MARK: - Selection with failed record
    
    func test_select_withFailedRecord_clearsPlayerAndShowsRecordError() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)

        let record = makeRecord(status: .failed, proxyRelativePath: nil, errorMessage: "Transcoding failed: unsupported codec")
        vm.records = [record]

        vm.select(recordID: record.id)

        XCTAssertNil(vm.player)
        XCTAssertEqual(vm.selectedRecordMessage, "Transcoding failed: unsupported codec")
        XCTAssertNil(vm.bannerMessage)
        XCTAssertEqual(spy.capturedProxyURLs.count, 0)
    }
    
    // MARK: - Selection with non-ready status
    
    func test_select_withAnalyzingRecord_clearsPlayerAndShowsGenericMessage() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)

        let record = makeRecord(status: .analyzing, proxyRelativePath: nil, errorMessage: nil)
        vm.records = [record]

        vm.select(recordID: record.id)

        XCTAssertNil(vm.player)
        XCTAssertEqual(vm.selectedRecordMessage, "Media is not ready for preview.")
        XCTAssertNil(vm.bannerMessage)
        XCTAssertEqual(spy.capturedProxyURLs.count, 0)
    }
    
    // MARK: - Multiple selections
    
    func test_select_calledTwice_replacesPlayer() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)

        let record1 = makeRecord(proxyRelativePath: "proxies/test1.mov")
        let record2 = makeRecord(proxyRelativePath: "proxies/test2.mov")
        vm.records = [record1, record2]

        vm.select(recordID: record1.id)
        let firstPlayer = vm.player

        vm.select(recordID: record2.id)
        let secondPlayer = vm.player
        
        XCTAssertNotNil(firstPlayer)
        XCTAssertNotNil(secondPlayer)
        XCTAssertNotIdentical(firstPlayer, secondPlayer)
        
        // Should have two captured calls
        XCTAssertEqual(spy.capturedProxyURLs.count, 2)
        XCTAssertEqual(spy.capturedProxyURLs[0].path, "/project/proxies/test1.mov")
        XCTAssertEqual(spy.capturedProxyURLs[1].path, "/project/proxies/test2.mov")
    }
    
    func test_select_readyThenFailed_keepsBlockingBannerNil_andUpdatesWorkspaceMessage() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let readyRecord = makeRecord(
            id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        )
        let failedRecord = makeRecord(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            status: .failed,
            proxyRelativePath: nil,
            errorMessage: "Import error"
        )

        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)
        vm.records = [readyRecord, failedRecord]

        vm.select(recordID: readyRecord.id)
        XCTAssertNotNil(vm.player)
        XCTAssertNil(vm.selectedRecordMessage)
        XCTAssertNil(vm.bannerMessage)

        vm.select(recordID: failedRecord.id)
        XCTAssertNil(vm.player)
        XCTAssertEqual(vm.selectedRecordMessage, "Import error")
        XCTAssertNil(vm.bannerMessage)
    }

    func test_selectRecordID_updatesWorkspaceSelectionWithoutBlockingBanner() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let record = makeRecord(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)

        vm.records = [record]
        vm.select(recordID: record.id)

        XCTAssertEqual(vm.selectedRecordID, record.id)
        XCTAssertEqual(vm.selectedRecord?.id, record.id)
        XCTAssertNil(vm.selectedRecordMessage)
        XCTAssertNil(vm.bannerMessage)
        XCTAssertEqual(spy.capturedProxyURLs.first?.path, "/project/media/proxies/sample.mov")
    }

    func test_selectRecordID_usesLocalWorkspaceMessage_forMissingRecord() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let record = makeRecord(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            status: .missing,
            proxyRelativePath: nil,
            errorMessage: "Original file is missing. Please relink it."
        )
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)

        vm.records = [record]
        vm.select(recordID: record.id)

        XCTAssertEqual(vm.selectedRecordID, record.id)
        XCTAssertEqual(vm.selectedRecordMessage, "Original file is missing. Please relink it.")
        XCTAssertNil(vm.player)
        XCTAssertNil(vm.bannerMessage)
    }
    
    // MARK: - Task 7: Import Integration
    
    func test_importLocalVideo_setsBannerMessageOnFailure() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        
        let spy = SpyPlaybackCore()
        let stubMediaCore = StubMediaCore()
        stubMediaCore.importResult = .failure(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported codec"]))
        
        let vm = MediaCoreViewModel(playbackCore: spy, mediaCore: stubMediaCore, store: store)
        
        let testURL = temp.url.appending(path: "test.mp4")
        try Data("test".utf8).write(to: testURL)
        
        await vm.importLocalVideo(url: testURL)
        
        // Should surface error in banner
        XCTAssertNotNil(vm.bannerMessage)
        XCTAssertTrue(vm.bannerMessage?.contains("Unsupported codec") ?? false)
        
        // Should not have created a player
        XCTAssertNil(vm.player)
    }
    
    func test_importLocalVideo_successfulImportLoadsRecordsAndSelectsImported() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        
        // Setup a real MediaCore with stub components
        let analyzer = StubAnalyzer(summary: .init(
            durationSeconds: 10.0,
            width: 1920,
            height: 1080,
            nominalFPS: 30.0,
            hasAudio: true
        ))
        let transcoder = StubTranscoder(result: .success)
        let mediaCore = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: transcoder, fallbackTranscoder: nil)
        
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, mediaCore: mediaCore, store: store, projectRoot: temp.url)
        
        // Create a test file
        let testURL = temp.url.appending(path: "test.mp4")
        try Data("test video content".utf8).write(to: testURL)
        
        // Import should succeed
        await vm.importLocalVideo(url: testURL)
        
        // Should have loaded records
        XCTAssertEqual(vm.records.count, 1)
        
        // Should have selected the imported record
        let importedRecord = vm.records[0]
        XCTAssertEqual(importedRecord.status, .ready)
        XCTAssertNotNil(importedRecord.derived.proxyRelativePath)
        
        // Should have created a player via the spy
        XCTAssertNotNil(vm.player)
        XCTAssertEqual(spy.capturedProxyURLs.count, 1)
        
        // Should have no banner error
        XCTAssertNil(vm.bannerMessage)
    }

    func test_importLocalVideo_setsSelectedRecordID_forWorkspaceSync() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()

        let analyzer = StubAnalyzer(summary: .init(
            durationSeconds: 10,
            width: 1920,
            height: 1080,
            nominalFPS: 30,
            hasAudio: true
        ))
        let transcoder = StubTranscoder(result: .success)
        let mediaCore = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: transcoder, fallbackTranscoder: nil)
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(
            playbackCore: spy,
            mediaCore: mediaCore,
            store: store,
            projectRoot: temp.url
        )

        let sourceURL = temp.url.appending(path: "source.mp4")
        try Data("clip".utf8).write(to: sourceURL)

        await vm.importLocalVideo(url: sourceURL)

        XCTAssertEqual(vm.records.count, 1)
        XCTAssertEqual(vm.selectedRecordID, vm.records[0].id)
        XCTAssertEqual(vm.selectedRecord?.status, .ready)
        XCTAssertNotNil(vm.player)

        let mediaId = vm.records[0].id
        XCTAssertEqual(
            spy.capturedProxyURLs.last?.path,
            temp.url.appending(path: "media/proxies/\(mediaId.uuidString).mov").path
        )
    }

    func test_importLocalVideo_loadFailure_keepsSelectionAndPlayerCleared() async {
        let importedId = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let existingId = UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
        let spy = SpyPlaybackCore()
        let stubMediaCore = StubMediaCore()
        stubMediaCore.importResult = .success(importedId)
        let store = ProjectStore(projectRoot: URL(fileURLWithPath: "/nonexistent/path"))
        let projectRoot = URL(fileURLWithPath: "/project")
        let vm = MediaCoreViewModel(
            playbackCore: spy,
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: projectRoot
        )

        vm.records = [makeRecord(id: existingId, proxyRelativePath: "proxies/existing.mov")]
        vm.select(recordID: existingId)
        XCTAssertEqual(vm.selectedRecordID, existingId)
        XCTAssertNotNil(vm.player)

        await vm.importLocalVideo(url: projectRoot.appending(path: "new-import.mov"))

        XCTAssertEqual(vm.records, [])
        XCTAssertNil(vm.selectedRecordID)
        XCTAssertNil(vm.selectedRecord)
        XCTAssertNil(vm.player)
        XCTAssertNotNil(vm.bannerMessage)
        XCTAssertTrue((vm.bannerMessage ?? "").count > 0)
    }
    
    func test_loadRecords_surfacesLoadErrors() async throws {
        let spy = SpyPlaybackCore()
        let stubMediaCore = StubMediaCore()
        // Create a store pointing to a non-existent directory
        let store = ProjectStore(projectRoot: URL(fileURLWithPath: "/nonexistent/path"))
        
        let vm = MediaCoreViewModel(playbackCore: spy, mediaCore: stubMediaCore, store: store)
        
        await vm.loadRecords()
        
        // Should surface load error in banner
        XCTAssertNotNil(vm.bannerMessage)
        XCTAssertTrue((vm.bannerMessage ?? "").count > 0)
    }

    func test_loadRecords_failure_clearsSelectedRecordIDAndPlayer() async throws {
        let spy = SpyPlaybackCore()
        let stubMediaCore = StubMediaCore()
        let store = ProjectStore(projectRoot: URL(fileURLWithPath: "/nonexistent/path"))
        let projectRoot = URL(fileURLWithPath: "/project")
        let record = makeRecord(id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        let vm = MediaCoreViewModel(
            playbackCore: spy,
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: projectRoot
        )

        vm.records = [record]
        vm.select(recordID: record.id)
        XCTAssertEqual(vm.selectedRecordID, record.id)
        XCTAssertNotNil(vm.player)

        await vm.loadRecords()

        XCTAssertEqual(vm.records, [])
        XCTAssertNil(vm.selectedRecordID)
        XCTAssertNil(vm.player)
        XCTAssertNotNil(vm.bannerMessage)
    }

    func test_loadRecords_successfulRecovery_clearsStaleBannerMessage() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()

        let recoveredRecord = makeRecord(
            id: UUID(uuidString: "EFEFEFEF-EFEF-EFEF-EFEF-EFEFEFEFEFEF")!,
            proxyRelativePath: "media/proxies/recovered.mov"
        )
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(
            playbackCore: spy,
            store: store,
            projectRoot: temp.url
        )

        try FileManager.default.removeItem(at: store.manifestURL)

        await vm.loadRecords()

        // When manifest is deleted but parent dir exists, loadManifest returns
        // empty manifest (graceful recovery for DB clear). No error banner.
        XCTAssertNil(vm.bannerMessage)
        XCTAssertEqual(vm.records, [])

        try store.saveManifest(MediaManifest(media: [recoveredRecord]))

        await vm.loadRecords()

        XCTAssertNil(vm.bannerMessage)
        XCTAssertEqual(vm.records.count, 1)
        XCTAssertEqual(vm.records.first?.id, recoveredRecord.id)
        XCTAssertEqual(vm.records.first?.status, .ready)
        XCTAssertEqual(vm.records.first?.derived.proxyRelativePath, recoveredRecord.derived.proxyRelativePath)
        XCTAssertNil(vm.selectedRecordMessage)
    }
    
    // MARK: - Task 8: Missing record selection
    
    func test_select_withMissingRecord_clearsPlayerAndShowsRelinkMessage() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)

        let record = makeRecord(
            status: .missing,
            proxyRelativePath: nil,
            errorMessage: "Original file is missing. Please relink it."
        )
        vm.records = [record]

        vm.select(recordID: record.id)

        XCTAssertNil(vm.player)
        XCTAssertEqual(vm.selectedRecordMessage, "Original file is missing. Please relink it.")
        XCTAssertNil(vm.bannerMessage)
        XCTAssertEqual(spy.capturedProxyURLs.count, 0)
    }
    
    // MARK: - Task 8: Relink flow
    
    func test_relinkOriginal_reloadsRecordsAndClearsPlayer() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        
        // Create a missing record
        let mediaId = UUID()
        var manifest = try store.loadManifest()
        manifest.media.append(MediaAssetRecord(
            id: mediaId,
            sourcePath: "/old/missing.mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc123"),
            status: .missing,
            analysis: nil,
            derived: .init(proxyRelativePath: nil, thumbnailsReady: false, waveformsReady: false),
            errorMessage: "Original file is missing. Please relink it.",
            usedFallbackTranscoder: false
        ))
        try store.saveManifest(manifest)
        
        // Setup view model with MediaCore
        let analyzer = StubAnalyzer(summary: .init(durationSeconds: 1, width: 640, height: 360, nominalFPS: 30, hasAudio: true))
        let transcoder = StubTranscoder(result: .success)
        let mediaCore = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: transcoder, fallbackTranscoder: nil)
        
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, mediaCore: mediaCore, store: store)
        
        // Load initial records (no validation needed - we just created the manifest)
        await vm.loadRecords(validateSources: false)
        XCTAssertEqual(vm.records.count, 1)
        XCTAssertEqual(vm.records[0].status, .missing)
        
        // Create new source file and relink
        let newURL = temp.url.appending(path: "new_source.mp4")
        try Data("new content".utf8).write(to: newURL)
        
        await vm.relinkOriginal(mediaId: mediaId, newURL: newURL)
        
        // Should have reloaded records
        XCTAssertEqual(vm.records.count, 1)
        let relinkedRecord = vm.records[0]
        
        // Should be queued for rebuild
        XCTAssertEqual(relinkedRecord.status, .queued)
        XCTAssertEqual(relinkedRecord.sourcePath, newURL.path)
        XCTAssertNil(relinkedRecord.errorMessage)
        
        // Should have cleared player
        XCTAssertNil(vm.player)
    }

    func test_relinkOriginal_reappliesSelectionAfterReload() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()

        let mediaId = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let relinkedRecord = MediaAssetRecord(
            id: mediaId,
            sourcePath: temp.url.appending(path: "relinked.mp4").path,
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "def456"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 3, width: 1280, height: 720, nominalFPS: 24, hasAudio: true),
            derived: .init(
                proxyRelativePath: "media/proxies/\(mediaId.uuidString).mov",
                thumbnailsReady: true,
                waveformsReady: false
            ),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )

        let stubMediaCore = StubMediaCore()
        stubMediaCore.relinkHandler = { _, _ in
            try store.saveManifest(MediaManifest(media: [relinkedRecord]))
        }

        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(
            playbackCore: spy,
            mediaCore: stubMediaCore,
            store: store,
            projectRoot: temp.url
        )

        await vm.relinkOriginal(mediaId: mediaId, newURL: temp.url.appending(path: "replacement.mov"))

        XCTAssertEqual(vm.records.count, 1)
        XCTAssertEqual(vm.records[0].id, relinkedRecord.id)
        XCTAssertEqual(vm.records[0].sourcePath, relinkedRecord.sourcePath)
        XCTAssertEqual(vm.records[0].status, .ready)
        XCTAssertEqual(vm.records[0].derived.proxyRelativePath, relinkedRecord.derived.proxyRelativePath)
        XCTAssertEqual(vm.selectedRecordID, mediaId)
        XCTAssertEqual(vm.selectedRecord?.id, mediaId)
        XCTAssertNotNil(vm.player)
        XCTAssertEqual(
            spy.capturedProxyURLs.last?.path,
            temp.url.appending(path: "media/proxies/\(mediaId.uuidString).mov").path
        )
    }
    
    func test_relinkOriginal_surfacesErrors() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        
        let analyzer = StubAnalyzer(summary: .init(durationSeconds: 1, width: 640, height: 360, nominalFPS: 30, hasAudio: true))
        let transcoder = StubTranscoder(result: .success)
        let mediaCore = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: transcoder, fallbackTranscoder: nil)
        
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, mediaCore: mediaCore, store: store)
        
        // Try to relink a non-existent record
        let nonExistentId = UUID()
        let newURL = temp.url.appending(path: "new_source.mp4")
        try Data("content".utf8).write(to: newURL)
        
        await vm.relinkOriginal(mediaId: nonExistentId, newURL: newURL)
        
        // Should surface error in banner
        XCTAssertNotNil(vm.bannerMessage)
        let message = vm.bannerMessage ?? ""
        XCTAssertFalse(message.isEmpty, "Expected error message but got: \(message)")
    }

    // MARK: - Task 3: Proxy prewarm

    func test_select_prewarmsSelectedAndAdjacentReadyProxyRecords() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)

        let first = makeRecord(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            proxyRelativePath: "media/proxies/first.mov"
        )
        let middle = makeRecord(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            proxyRelativePath: "media/proxies/middle.mov"
        )
        let failed = makeRecord(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            status: .failed,
            proxyRelativePath: nil,
            errorMessage: "bad clip"
        )
        vm.records = [first, middle, failed]

        vm.select(recordID: middle.id)

        XCTAssertEqual(
            spy.preparedProxyURLBatches.last?.map(\.path),
            [
                "/project/media/proxies/first.mov",
                "/project/media/proxies/middle.mov"
            ]
        )
    }

    /// When `loadRecords()` reloads records that contain the already-selected ID,
    /// the view model should re-invoke `select(recordID:)` which triggers
    /// `prewarmVisibleProxies()` — covering the "reload preserved selection" prewarm path.
    func test_loadRecords_withPreservedSelection_prewarmsSelectedAndAdjacentProxies() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()

        let selectedID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let prev = makeRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            proxyRelativePath: "media/proxies/prev.mov"
        )
        let selected = makeRecord(
            id: selectedID,
            proxyRelativePath: "media/proxies/selected.mov"
        )
        let next = makeRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            proxyRelativePath: "media/proxies/next.mov"
        )

        try store.saveManifest(MediaManifest(media: [prev, selected, next]))

        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, store: store, projectRoot: temp.url)

        // Set selection before loading — simulates restoring workspace state.
        // This does NOT call select(), so no prewarm batches are emitted yet.
        vm.selectedRecordID = selectedID

        await vm.loadRecords()

        // loadRecords() detects the preserved selection and calls select(recordID:),
        // which triggers prewarmVisibleProxies(). Exactly one batch should be emitted.
        XCTAssertEqual(spy.preparedProxyURLBatches.count, 1, "Expected exactly one prewarm batch from the reload-preserved-selection path")

        let expectedPaths = [
            temp.url.appending(path: "media/proxies/prev.mov").path,
            temp.url.appending(path: "media/proxies/selected.mov").path,
            temp.url.appending(path: "media/proxies/next.mov").path,
        ]
        XCTAssertEqual(
            spy.preparedProxyURLBatches.last?.map(\.path),
            expectedPaths,
            "Prewarm batch should contain selected record plus one adjacent record on each side"
        )
    }

    func test_proxyPrewarmPlan_skipsNonReadyAndMissingProxyRecords() {
        let records = [
            makeRecord(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                proxyRelativePath: "media/proxies/first.mov"
            ),
            makeRecord(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                status: .analyzing,
                proxyRelativePath: nil
            ),
            makeRecord(
                id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                proxyRelativePath: "media/proxies/third.mov"
            )
        ]

        let urls = ProxyPrewarmPlan.urls(
            records: records,
            selectedRecordID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            projectRoot: URL(fileURLWithPath: "/project"),
            radius: 2
        )

        XCTAssertEqual(
            urls.map(\.path),
            [
                "/project/media/proxies/first.mov",
                "/project/media/proxies/third.mov"
            ]
        )
    }

    // MARK: - Timeline Editing Operations

    func test_handleSegmentClick_plainClick_selectsSingleSegment() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let firstID = UUID()
        let secondID = UUID()
        vm.timelineSegments = [
            TimelineSegment(id: firstID, sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 3), text: "A", subtitles: []),
            TimelineSegment(id: secondID, sourceVideoID: UUID(), range: TimeRange(startSeconds: 3, endSeconds: 6), text: "B", subtitles: [])
        ]

        vm.handleSegmentClick(index: 1)

        XCTAssertEqual(vm.selectedSegmentID, secondID)
        XCTAssertEqual(vm.selectedSegmentIDs, Set([secondID]))
        XCTAssertEqual(vm.selectedSegmentIndices, IndexSet(integer: 1))
    }

    func test_handleSegmentClick_commandClick_togglesNonContiguousSelection() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let ids = [UUID(), UUID(), UUID()]
        vm.timelineSegments = [
            TimelineSegment(id: ids[0], sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 3), text: "A", subtitles: []),
            TimelineSegment(id: ids[1], sourceVideoID: UUID(), range: TimeRange(startSeconds: 3, endSeconds: 6), text: "B", subtitles: []),
            TimelineSegment(id: ids[2], sourceVideoID: UUID(), range: TimeRange(startSeconds: 6, endSeconds: 9), text: "C", subtitles: [])
        ]

        vm.handleSegmentClick(index: 0)
        vm.handleSegmentClick(index: 2, modifiers: [.command])

        XCTAssertEqual(vm.selectedSegmentIDs, Set([ids[0], ids[2]]))
        XCTAssertEqual(vm.selectedSegmentID, ids[2])
        XCTAssertEqual(vm.selectedSegmentIndices, IndexSet([0, 2]))

        vm.handleSegmentClick(index: 0, modifiers: [.command])
        XCTAssertEqual(vm.selectedSegmentIDs, Set([ids[2]]))
        XCTAssertEqual(vm.selectedSegmentID, ids[2])
    }

    func test_handleSegmentClick_shiftClick_selectsContiguousRangeFromAnchor() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let ids = [UUID(), UUID(), UUID(), UUID()]
        vm.timelineSegments = [
            TimelineSegment(id: ids[0], sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 2), text: "A", subtitles: []),
            TimelineSegment(id: ids[1], sourceVideoID: UUID(), range: TimeRange(startSeconds: 2, endSeconds: 4), text: "B", subtitles: []),
            TimelineSegment(id: ids[2], sourceVideoID: UUID(), range: TimeRange(startSeconds: 4, endSeconds: 6), text: "C", subtitles: []),
            TimelineSegment(id: ids[3], sourceVideoID: UUID(), range: TimeRange(startSeconds: 6, endSeconds: 8), text: "D", subtitles: [])
        ]

        vm.handleSegmentClick(index: 1)
        vm.handleSegmentClick(index: 3, modifiers: [.shift])

        XCTAssertEqual(vm.selectedSegmentIDs, Set([ids[1], ids[2], ids[3]]))
        XCTAssertEqual(vm.selectedSegmentIndices, IndexSet([1, 2, 3]))
        XCTAssertEqual(vm.selectedSegmentID, ids[3])
    }

    func test_selectAllAndDeleteSelectedSegments_removeMultipleSegments() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let ids = [UUID(), UUID(), UUID()]
        vm.timelineSegments = [
            TimelineSegment(id: ids[0], sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 3), text: "A", subtitles: []),
            TimelineSegment(id: ids[1], sourceVideoID: UUID(), range: TimeRange(startSeconds: 3, endSeconds: 6), text: "B", subtitles: []),
            TimelineSegment(id: ids[2], sourceVideoID: UUID(), range: TimeRange(startSeconds: 6, endSeconds: 9), text: "C", subtitles: [])
        ]

        vm.selectAllSegments()
        XCTAssertEqual(vm.selectedSegmentIDs, Set(ids))
        XCTAssertEqual(vm.selectedSegmentCount, 3)

        vm.deleteSelectedSegments()
        XCTAssertTrue(vm.timelineSegments.isEmpty)
        XCTAssertTrue(vm.selectedSegmentIDs.isEmpty)
    }

    func test_splitAtPlayhead_splitsSegmentIntoTwo() {
        let spy = SpyPlaybackCore()
        let projectRoot = URL(fileURLWithPath: "/project")
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: projectRoot)

        let record = makeRecord(proxyRelativePath: "proxies/test.mov")
        vm.records = [record]
        vm.select(recordID: record.id)

        // Manually set up timeline segments (simulating AI result)
        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 10), text: "Full segment", subtitles: [])
        ]

        // Split at composed time 4.0 (within the segment)
        vm.splitAtPlayhead(composedTime: 4.0)

        XCTAssertEqual(vm.timelineSegments.count, 2)
        XCTAssertEqual(vm.timelineSegments[0].range.startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[0].range.endSeconds, 4.0, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[1].range.startSeconds, 4.0, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[1].range.endSeconds, 10.0, accuracy: 0.001)
        XCTAssertTrue(vm.canUndo)
    }

    func test_splitAtPlayhead_rejectsSplitNearEdge() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)

        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 10), text: "", subtitles: [])
        ]

        // Split too close to start — should be rejected
        vm.splitAtPlayhead(composedTime: 0.1)
        XCTAssertEqual(vm.timelineSegments.count, 1)

        // Split too close to end — should be rejected
        vm.splitAtPlayhead(composedTime: 9.95)
        XCTAssertEqual(vm.timelineSegments.count, 1)
    }

    func test_deleteSegment_removesAndAdjustsSelection() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)

        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        vm.timelineSegments = [
            TimelineSegment(id: id1, sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 3), text: "A", subtitles: []),
            TimelineSegment(id: id2, sourceVideoID: UUID(), range: TimeRange(startSeconds: 3, endSeconds: 6), text: "B", subtitles: []),
            TimelineSegment(id: id3, sourceVideoID: UUID(), range: TimeRange(startSeconds: 6, endSeconds: 9), text: "C", subtitles: []),
        ]
        vm.selectedSegmentID = id2

        vm.deleteSegment(at: 1)

        XCTAssertEqual(vm.timelineSegments.count, 2)
        XCTAssertEqual(vm.timelineSegments[0].id, id1)
        XCTAssertEqual(vm.timelineSegments[1].id, id3)
        // Selection should move to next available
        XCTAssertNotNil(vm.selectedSegmentID)
        XCTAssertTrue(vm.canUndo)
    }

    func test_deleteSegment_clearsPlayerWhenEmpty() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)

        let segId = UUID()
        vm.timelineSegments = [
            TimelineSegment(id: segId, sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 5), text: "", subtitles: [])
        ]
        vm.selectedSegmentID = segId

        vm.deleteSegment(at: 0)

        XCTAssertTrue(vm.timelineSegments.isEmpty)
        XCTAssertNil(vm.selectedSegmentID)
    }

    func test_insertManualSegment_addsAndSelectsNewSegment() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)

        vm.timelineSegments = []
        vm.insertManualSegment(range: TimeRange(startSeconds: 2, endSeconds: 7), at: 0)

        XCTAssertEqual(vm.timelineSegments.count, 1)
        XCTAssertEqual(vm.timelineSegments[0].range.startSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[0].range.endSeconds, 7, accuracy: 0.001)
        XCTAssertEqual(vm.selectedSegmentID, vm.timelineSegments[0].id)
        XCTAssertTrue(vm.canUndo)
    }

    func test_insertManualSegment_rejectsTooShort() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        vm.records = [makeRecord()]

        vm.insertManualSegment(range: TimeRange(startSeconds: 0, endSeconds: 0.1), at: 0)
        XCTAssertTrue(vm.timelineSegments.isEmpty)
    }

    // MARK: - insertSourceSlice (Highlights panel drop path)

    func test_insertSourceSlice_addsClampedSegmentAndSelectsIt() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)

        vm.timelineSegments = []
        vm.insertSourceSlice(mediaID: record.id, sourceStart: 12, sourceEnd: 18, at: 0)

        XCTAssertEqual(vm.timelineSegments.count, 1)
        XCTAssertEqual(vm.timelineSegments[0].sourceVideoID, record.id)
        XCTAssertEqual(vm.timelineSegments[0].range.startSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[0].range.endSeconds, 18, accuracy: 0.001)
        XCTAssertEqual(vm.selectedSegmentID, vm.timelineSegments[0].id)
        XCTAssertTrue(vm.canUndo)
    }

    func test_insertSourceSlice_clampsToSourceDuration() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        let record = makeRecord() // analysis.durationSeconds = 300
        vm.records = [record]

        // Request a slice that runs past the source's end — clamp to
        // [start, sourceDuration] so the dropped clip never points at
        // missing video data.
        vm.insertSourceSlice(mediaID: record.id, sourceStart: 295, sourceEnd: 600, at: 0)

        XCTAssertEqual(vm.timelineSegments.count, 1)
        XCTAssertEqual(vm.timelineSegments[0].range.startSeconds, 295, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[0].range.endSeconds, 300, accuracy: 0.001)
    }

    func test_insertSourceSlice_rejectsSpanShorterThanMinimum() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        let record = makeRecord()
        vm.records = [record]

        // 0.05s span — shorter than the 0.2s floor — must be rejected
        // with a banner; no segment inserted.
        vm.insertSourceSlice(mediaID: record.id, sourceStart: 10, sourceEnd: 10.05, at: 0)
        XCTAssertTrue(vm.timelineSegments.isEmpty)
        XCTAssertEqual(vm.bannerMessage, L("Can't add highlight — selection is out of range."))
    }

    func test_insertSourceSlice_rejectsMissingMedia() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        vm.records = []

        vm.insertSourceSlice(mediaID: UUID(), sourceStart: 0, sourceEnd: 1, at: 0)
        XCTAssertTrue(vm.timelineSegments.isEmpty)
        XCTAssertEqual(vm.bannerMessage, L("Can't add highlight — media not found."))
    }

    func test_insertSourceSlice_rejectsRecordWithoutAnalysis() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        // Record without analysis — represents a freshly-imported clip
        // whose pipeline hasn't finished yet. Highlights drop should
        // refuse instead of inserting a degenerate segment.
        let id = UUID()
        let unanalyzed = MediaAssetRecord(
            id: id,
            sourcePath: "/tmp/\(id.uuidString).mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc"),
            status: .analyzing,
            analysis: nil,
            derived: DerivedAssetState(proxyRelativePath: nil, thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        vm.records = [unanalyzed]

        vm.insertSourceSlice(mediaID: id, sourceStart: 0, sourceEnd: 5, at: 0)
        XCTAssertTrue(vm.timelineSegments.isEmpty)
        XCTAssertEqual(vm.bannerMessage, L("Can't add highlight — analysis not ready."))
    }

    // MARK: - Manual highlights (PR 10)

    private func makeHighlightCopilotSnapshot(markers: [AICopilotMarker] = []) -> AICopilotSnapshot {
        AICopilotSnapshot(
            semanticTags: [],
            summary: nil,
            transcriptPreview: nil,
            suggestedInSeconds: nil,
            suggestedOutSeconds: nil,
            issues: [],
            suggestions: [],
            markers: markers
        )
    }

    private func makeRecordWithSnapshot(
        id: UUID = UUID(),
        markers: [AICopilotMarker] = []
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: id,
            sourcePath: "/tmp/\(id.uuidString).mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 300, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: "media/proxies/sample.mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            copilot: makeHighlightCopilotSnapshot(markers: markers)
        )
    }

    func test_addManualHighlight_appendsManualOriginMarker() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]

        vm.addManualHighlight(recordID: record.id, sourceStart: 12, sourceEnd: 18, label: "Best line")

        let markers = vm.records[0].copilot?.markers ?? []
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].kind, .highlight)
        XCTAssertEqual(markers[0].origin, .manual)
        XCTAssertEqual(markers[0].seconds, 12, accuracy: 0.001)
        XCTAssertEqual(markers[0].endSeconds, 18)
        XCTAssertEqual(markers[0].label, "Best line")
        XCTAssertEqual(vm.bannerMessage, L("Highlight saved."))
    }

    func test_addManualHighlight_clampsToSourceDuration() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]

        // Source duration is 300; ask for 295–600 → clamp to 295–300.
        vm.addManualHighlight(recordID: record.id, sourceStart: 295, sourceEnd: 600, label: "")
        let markers = vm.records[0].copilot?.markers ?? []
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].seconds, 295, accuracy: 0.001)
        XCTAssertEqual(markers[0].endSeconds, 300)
        // Empty label falls back to the localized "Manual highlight" placeholder.
        XCTAssertEqual(markers[0].label, L("Manual highlight"))
    }

    func test_addManualHighlight_rejectsUnknownRecord() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        vm.records = []
        vm.addManualHighlight(recordID: UUID(), sourceStart: 0, sourceEnd: 1, label: "x")
        XCTAssertEqual(vm.bannerMessage, L("Can't save highlight — media not found."))
    }

    func test_addManualHighlight_rejectsWhenSpanTooShort() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]
        vm.addManualHighlight(recordID: record.id, sourceStart: 10, sourceEnd: 10.05, label: "x")
        XCTAssertTrue(vm.records[0].copilot?.markers.isEmpty ?? false)
        XCTAssertEqual(vm.bannerMessage, L("Can't save highlight — selection is too short."))
    }

    func test_addManualHighlight_rejectsRecordWithoutSnapshot() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecord()  // no copilot snapshot
        vm.records = [record]
        vm.addManualHighlight(recordID: record.id, sourceStart: 0, sourceEnd: 5, label: "x")
        XCTAssertEqual(vm.bannerMessage, L("Can't save highlight — run AI analysis first."))
    }

    func test_addManualHighlight_truncatesLongLabels() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]
        let long = String(repeating: "字", count: 100)
        vm.addManualHighlight(recordID: record.id, sourceStart: 5, sourceEnd: 8, label: long)
        let label = vm.records[0].copilot?.markers.first?.label ?? ""
        // Cap is 60 chars; result should be shorter than input.
        XCTAssertLessThanOrEqual(label.count, 60)
    }

    func test_addManualHighlight_preservesOtherMarkerKinds() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot(markers: [
            AICopilotMarker(kind: .scene, seconds: 0, label: "Scene A"),
            AICopilotMarker(kind: .highlight, seconds: 1, endSeconds: 3, label: "AI", origin: .ai)
        ])
        vm.records = [record]
        vm.addManualHighlight(recordID: record.id, sourceStart: 5, sourceEnd: 8, label: "Mine")
        let kinds = vm.records[0].copilot?.markers.map(\.kind) ?? []
        XCTAssertEqual(kinds, [.scene, .highlight, .highlight])
        XCTAssertEqual(vm.records[0].copilot?.markers.last?.origin, .manual)
    }

    func test_saveTimelineSegmentsToHighlights_bulkSavesAcrossRecords() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let r1 = makeRecordWithSnapshot()
        let r2 = makeRecordWithSnapshot()
        vm.records = [r1, r2]
        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: r1.id, range: TimeRange(startSeconds: 1, endSeconds: 4), text: "A1", subtitles: []),
            TimelineSegment(id: UUID(), sourceVideoID: r1.id, range: TimeRange(startSeconds: 10, endSeconds: 12), text: "A2", subtitles: []),
            TimelineSegment(id: UUID(), sourceVideoID: r2.id, range: TimeRange(startSeconds: 5, endSeconds: 8), text: "B1", subtitles: [])
        ]
        let allIDs = vm.timelineSegments.map(\.id)
        vm.saveTimelineSegmentsToHighlights(allIDs)

        let r1Markers = vm.records.first(where: { $0.id == r1.id })?.copilot?.markers ?? []
        let r2Markers = vm.records.first(where: { $0.id == r2.id })?.copilot?.markers ?? []
        XCTAssertEqual(r1Markers.count, 2)
        XCTAssertEqual(r2Markers.count, 1)
        XCTAssertTrue(r1Markers.allSatisfy { $0.origin == .manual && $0.kind == .highlight })
        XCTAssertEqual(vm.bannerMessage, L("Saved %d highlights.", 3))
    }

    func test_saveTimelineSegmentsToHighlights_ignoresMissingSegments() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let r1 = makeRecordWithSnapshot()
        vm.records = [r1]
        vm.timelineSegments = []
        vm.saveTimelineSegmentsToHighlights([UUID(), UUID()])
        XCTAssertTrue(vm.records[0].copilot?.markers.isEmpty ?? true)
        XCTAssertEqual(vm.bannerMessage, L("Couldn't save any highlights — check the analysis status."))
    }

    func test_saveTimelineSegmentsToHighlights_skipsSegmentsWithMissingSnapshot() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let withSnap = makeRecordWithSnapshot()
        let withoutSnap = makeRecord()  // no copilot
        vm.records = [withSnap, withoutSnap]
        let segWithSnap = TimelineSegment(id: UUID(), sourceVideoID: withSnap.id, range: TimeRange(startSeconds: 1, endSeconds: 4), text: "Good", subtitles: [])
        let segWithoutSnap = TimelineSegment(id: UUID(), sourceVideoID: withoutSnap.id, range: TimeRange(startSeconds: 1, endSeconds: 4), text: "Skip", subtitles: [])
        vm.timelineSegments = [segWithSnap, segWithoutSnap]
        vm.saveTimelineSegmentsToHighlights([segWithSnap.id, segWithoutSnap.id])

        XCTAssertEqual(vm.records.first(where: { $0.id == withSnap.id })?.copilot?.markers.count, 1)
        XCTAssertNil(vm.records.first(where: { $0.id == withoutSnap.id })?.copilot)
        XCTAssertEqual(vm.bannerMessage, L("Saved %d highlights (%d skipped).", 1, 1))
    }

    func test_canSaveSegmentToHighlights_truthTable() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let withSnap = makeRecordWithSnapshot()
        let withoutSnap = makeRecord()
        vm.records = [withSnap, withoutSnap]

        let goodSeg = TimelineSegment(id: UUID(), sourceVideoID: withSnap.id, range: TimeRange(startSeconds: 1, endSeconds: 4), text: "ok", subtitles: [])
        let noSnapSeg = TimelineSegment(id: UUID(), sourceVideoID: withoutSnap.id, range: TimeRange(startSeconds: 1, endSeconds: 4), text: "no", subtitles: [])
        let tinySeg = TimelineSegment(id: UUID(), sourceVideoID: withSnap.id, range: TimeRange(startSeconds: 10, endSeconds: 10.05), text: "tiny", subtitles: [])
        let orphanSeg = TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 1, endSeconds: 4), text: "orphan", subtitles: [])
        vm.timelineSegments = [goodSeg, noSnapSeg, tinySeg, orphanSeg]

        XCTAssertTrue(vm.canSaveSegmentToHighlights(segmentID: goodSeg.id))
        XCTAssertFalse(vm.canSaveSegmentToHighlights(segmentID: noSnapSeg.id))
        XCTAssertFalse(vm.canSaveSegmentToHighlights(segmentID: tinySeg.id))
        XCTAssertFalse(vm.canSaveSegmentToHighlights(segmentID: orphanSeg.id))
        XCTAssertFalse(vm.canSaveSegmentToHighlights(segmentID: UUID()))
    }

    func test_removeHighlight_removesByIndexWhenFingerprintMatches() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot(markers: [
            AICopilotMarker(kind: .scene, seconds: 0, label: "Scene"),
            AICopilotMarker(kind: .highlight, seconds: 5, endSeconds: 8, label: "Hook", origin: .ai)
        ])
        vm.records = [record]
        let fp = AICopilotPresentation.HighlightFingerprint(
            seconds: 5, endSeconds: 8, origin: .ai, label: "Hook"
        )
        vm.removeHighlight(recordID: record.id, markerIndex: 1, fingerprint: fp)

        let kinds = vm.records[0].copilot?.markers.map(\.kind) ?? []
        XCTAssertEqual(kinds, [.scene])
        XCTAssertEqual(vm.bannerMessage, L("Highlight removed."))
    }

    func test_removeHighlight_isNoOpWhenFingerprintMismatch() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot(markers: [
            AICopilotMarker(kind: .highlight, seconds: 5, endSeconds: 8, label: "AI replaced", origin: .ai)
        ])
        vm.records = [record]
        // Stale fingerprint pointing at a label that no longer matches.
        let staleFP = AICopilotPresentation.HighlightFingerprint(
            seconds: 5, endSeconds: 8, origin: .ai, label: "Old AI"
        )
        vm.removeHighlight(recordID: record.id, markerIndex: 0, fingerprint: staleFP)

        XCTAssertEqual(vm.records[0].copilot?.markers.count, 1)
        XCTAssertEqual(vm.bannerMessage, L("Highlight has changed. Try again."))
    }

    func test_removeHighlight_isNoOpForOutOfRangeIndex() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot(markers: [
            AICopilotMarker(kind: .highlight, seconds: 5, endSeconds: 8, label: "Hook")
        ])
        vm.records = [record]
        let fp = AICopilotPresentation.HighlightFingerprint(seconds: 5, endSeconds: 8, origin: .ai, label: "Hook")
        vm.removeHighlight(recordID: record.id, markerIndex: 99, fingerprint: fp)
        XCTAssertEqual(vm.records[0].copilot?.markers.count, 1)
        XCTAssertEqual(vm.bannerMessage, L("Highlight no longer exists."))
    }

    func test_removeHighlight_preservesUnrelatedMarkers() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot(markers: [
            AICopilotMarker(kind: .highlight, seconds: 1, endSeconds: 3, label: "First", origin: .ai),
            AICopilotMarker(kind: .scene, seconds: 2, label: "Scene"),
            AICopilotMarker(kind: .highlight, seconds: 5, endSeconds: 8, label: "Second", origin: .manual),
            AICopilotMarker(kind: .suggestion, seconds: 6, label: "Sug")
        ])
        vm.records = [record]
        // Remove the second highlight (markerIndex == 2 in raw array).
        let fp = AICopilotPresentation.HighlightFingerprint(
            seconds: 5, endSeconds: 8, origin: .manual, label: "Second"
        )
        vm.removeHighlight(recordID: record.id, markerIndex: 2, fingerprint: fp)

        let remaining = vm.records[0].copilot?.markers ?? []
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(remaining.map(\.kind), [.highlight, .scene, .suggestion])
        XCTAssertEqual(remaining[0].label, "First")
    }

    func test_manualHighlight_survivesScoreHookCandidatesRerun() {
        // Manual highlights must NEVER be wiped by a
        // score_hook_candidates rerun. We simulate the dispatcher's
        // mutation directly: filter out AI highlights, append the
        // new AI shortlist, and verify our manual marker stayed.
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]
        vm.addManualHighlight(recordID: record.id, sourceStart: 5, sourceEnd: 8, label: "Mine")
        // Inject an AI marker as if a previous run had landed.
        var snap = vm.records[0].copilot!
        snap.markers.append(AICopilotMarker(kind: .highlight, seconds: 50, endSeconds: 53, label: "Old AI", origin: .ai))
        vm.records[0].copilot = snap

        // Rerun: dispatcher's filter step keeps non-AI-highlight markers.
        var rerun = vm.records[0].copilot!
        rerun.markers = rerun.markers.filter { !($0.kind == .highlight && $0.origin == .ai) }
        rerun.markers.append(AICopilotMarker(kind: .highlight, seconds: 100, endSeconds: 103, label: "New AI", origin: .ai))
        vm.records[0].copilot = rerun

        let labels = vm.records[0].copilot?.markers.map(\.label) ?? []
        XCTAssertTrue(labels.contains("Mine"))
        XCTAssertTrue(labels.contains("New AI"))
        XCTAssertFalse(labels.contains("Old AI"))
    }

    // MARK: - Use as hook (PR 11)

    private func makeHookableHighlightRow(
        recordID: UUID,
        start: Double = 12,
        end: Double? = 18,
        label: String = "Hookable line",
        origin: AICopilotMarker.Origin = .manual,
        markerIndex: Int = 0
    ) -> AICopilotPresentation.HighlightRow {
        AICopilotPresentation.HighlightRow(
            sourceVideoID: recordID,
            seconds: start,
            endSeconds: end,
            label: label,
            origin: origin,
            markerIndex: markerIndex
        )
    }

    func test_canUseHighlightAsHook_truthTable() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]

        // Happy path — endSeconds set, scope empty, not processing,
        // record exists.
        let good = makeHookableHighlightRow(recordID: record.id)
        XCTAssertTrue(vm.canUseHighlightAsHook(good))

        // Legacy marker: no endSeconds → false.
        let legacy = makeHookableHighlightRow(recordID: record.id, end: nil)
        XCTAssertFalse(vm.canUseHighlightAsHook(legacy))

        // Unknown record → false.
        let orphan = makeHookableHighlightRow(recordID: UUID())
        XCTAssertFalse(vm.canUseHighlightAsHook(orphan))

        // Active agent run → false.
        vm.isChatProcessing = true
        XCTAssertFalse(vm.canUseHighlightAsHook(good))
        vm.isChatProcessing = false
        XCTAssertTrue(vm.canUseHighlightAsHook(good))
    }

    func test_useHighlightAsHook_insertsPendingProposalAndChatBubble() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]

        let row = makeHookableHighlightRow(recordID: record.id, start: 5, end: 12, label: "Killer line")
        let bubblesBefore = vm.chatMessages.count
        let proposalsBefore = vm.pendingProposals.count

        vm.useHighlightAsHook(row)

        XCTAssertEqual(vm.pendingProposals.count, proposalsBefore + 1, "Proposal should be inserted")
        // Proposal sits at index 0 — top of the queue.
        let proposal = vm.pendingProposals[0]
        XCTAssertEqual(proposal.batch.actions.count, 1)
        if case let .insertSourceClip(srcID, srcStart, srcEnd, insertAt, _, _) = proposal.batch.actions[0] {
            XCTAssertEqual(srcID, record.id)
            XCTAssertEqual(srcStart, 5, accuracy: 0.0001)
            XCTAssertEqual(srcEnd, 12, accuracy: 0.0001)
            XCTAssertEqual(insertAt, 0, accuracy: 0.0001)
        } else {
            XCTFail("Expected an insertSourceClip action")
        }
        // Synthetic toolCallID is namespaced so we can tell it apart
        // from LLM-driven proposals if anyone needs to.
        XCTAssertTrue(proposal.toolCallID.hasPrefix("ui-use-as-hook-"))

        // Chat bubble linking to the proposal so the card renders.
        XCTAssertEqual(vm.chatMessages.count, bubblesBefore + 1)
        let bubble = vm.chatMessages.last!
        XCTAssertEqual(bubble.proposedBatchID, proposal.id)
        XCTAssertEqual(bubble.role, .assistant)
        XCTAssertEqual(bubble.iconSystemName, "target")
        XCTAssertFalse(bubble.content.contains("🎯"), "Leading emoji should be stripped by extractLeadingIcon")

        // User-facing banner confirms the insert.
        XCTAssertNotNil(vm.bannerMessage)
    }

    func test_useHighlightAsHook_isNoOpWhenScopeChipsAttached() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]
        // Add a timeline segment + matching chat attachment so
        // `chatAttachmentScope` resolves to non-empty.
        let segID = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: segID,
                sourceVideoID: record.id,
                range: TimeRange(startSeconds: 0, endSeconds: 5),
                text: "",
                subtitles: []
            )
        ]
        vm.chatAttachments = [
            ChatAttachment(
                segmentID: segID,
                composedStart: 0,
                composedEnd: 5,
                sourceVideoID: record.id,
                sourceStartSeconds: 0
            )
        ]
        XCTAssertFalse(vm.chatAttachmentScope.entries.isEmpty)

        let row = makeHookableHighlightRow(recordID: record.id)
        XCTAssertFalse(vm.canUseHighlightAsHook(row))

        vm.useHighlightAsHook(row)
        XCTAssertTrue(vm.pendingProposals.isEmpty)
        XCTAssertTrue(vm.chatMessages.isEmpty)
        XCTAssertNotNil(vm.bannerMessage)
    }

    func test_useHighlightAsHook_isNoOpWhenAgentIsProcessing() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]
        vm.isChatProcessing = true

        let row = makeHookableHighlightRow(recordID: record.id)
        XCTAssertFalse(vm.canUseHighlightAsHook(row))

        vm.useHighlightAsHook(row)
        XCTAssertTrue(vm.pendingProposals.isEmpty)
        XCTAssertTrue(vm.chatMessages.isEmpty)
        XCTAssertNotNil(vm.bannerMessage)
    }

    func test_useHighlightAsHook_isNoOpWhenRecordMissing() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        // No records loaded — row points at an orphan UUID.
        let row = makeHookableHighlightRow(recordID: UUID())

        vm.useHighlightAsHook(row)
        XCTAssertTrue(vm.pendingProposals.isEmpty)
        XCTAssertTrue(vm.chatMessages.isEmpty)
        XCTAssertNotNil(vm.bannerMessage)
    }

    func test_useHighlightAsHook_isNoOpWhenEndSecondsMissing() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]
        let legacy = makeHookableHighlightRow(recordID: record.id, end: nil)

        vm.useHighlightAsHook(legacy)
        XCTAssertTrue(vm.pendingProposals.isEmpty)
        XCTAssertTrue(vm.chatMessages.isEmpty)
        XCTAssertNotNil(vm.bannerMessage)
    }

    func test_useHighlightAsHook_emptyLabelFallsBackToGenericExplanation() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]
        let row = makeHookableHighlightRow(
            recordID: record.id, start: 0, end: 5, label: "   "
        )

        vm.useHighlightAsHook(row)
        XCTAssertEqual(vm.pendingProposals.count, 1)
        let explanation = vm.pendingProposals[0].batch.explanation
        XCTAssertTrue(explanation.contains("Add opening hook teaser"))
        XCTAssertFalse(explanation.contains(":"), "No label means no \"Add opening hook: <label>\" form")
    }

    func test_useHighlightAsHook_labelBakesIntoExplanation() {
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let record = makeRecordWithSnapshot()
        vm.records = [record]
        let row = makeHookableHighlightRow(
            recordID: record.id, start: 0, end: 5, label: "Why most diets fail"
        )

        vm.useHighlightAsHook(row)
        XCTAssertEqual(vm.pendingProposals.count, 1)
        XCTAssertTrue(vm.pendingProposals[0].batch.explanation.contains("Why most diets fail"))
    }

    func test_setSegmentVolume_clampsAndUpdates() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)

        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 5), text: "", subtitles: [])
        ]

        vm.setSegmentVolume(at: 0, volume: 0.5)
        XCTAssertEqual(vm.timelineSegments[0].volumeLevel, 0.5, accuracy: 0.001)

        vm.setSegmentVolume(at: 0, volume: -0.5)
        XCTAssertEqual(vm.timelineSegments[0].volumeLevel, 0, accuracy: 0.001)

        vm.setSegmentVolume(at: 0, volume: 1.5)
        XCTAssertEqual(vm.timelineSegments[0].volumeLevel, 1, accuracy: 0.001)
    }

    func test_setSegmentSpeed_clampsAndUpdates() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)

        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 8), text: "", subtitles: [])
        ]

        vm.setSegmentSpeed(at: 0, rate: 2.0)
        XCTAssertEqual(vm.timelineSegments[0].normalizedSpeedRate, 2.0, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[0].durationSeconds, 4.0, accuracy: 0.001)

        vm.setSegmentSpeed(at: 0, rate: 99)
        XCTAssertEqual(vm.timelineSegments[0].normalizedSpeedRate, TimelineSegment.maximumSpeedRate, accuracy: 0.001)

        vm.setSegmentSpeed(at: 0, rate: 0.01)
        XCTAssertEqual(vm.timelineSegments[0].normalizedSpeedRate, TimelineSegment.minimumSpeedRate, accuracy: 0.001)
    }

    func test_setSelectedSegmentsSpeed_updatesAllSelectedSegments() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let ids = [UUID(), UUID(), UUID()]
        vm.timelineSegments = [
            TimelineSegment(id: ids[0], sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 4), text: "A", subtitles: []),
            TimelineSegment(id: ids[1], sourceVideoID: UUID(), range: TimeRange(startSeconds: 4, endSeconds: 8), text: "B", subtitles: []),
            TimelineSegment(id: ids[2], sourceVideoID: UUID(), range: TimeRange(startSeconds: 8, endSeconds: 12), text: "C", subtitles: [])
        ]

        vm.handleSegmentClick(index: 0)
        vm.handleSegmentClick(index: 2, modifiers: [.command])
        vm.setSelectedSegmentsSpeed(1.5)

        XCTAssertEqual(vm.timelineSegments[0].normalizedSpeedRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[1].normalizedSpeedRate, 1.0, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[2].normalizedSpeedRate, 1.5, accuracy: 0.001)
        XCTAssertEqual(vm.selectedSegmentIDs, Set([ids[0], ids[2]]))
        XCTAssertTrue(vm.canUndo)
    }

    func test_undo_restoresPreviousState_afterSplit() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)

        let originalID = UUID()
        vm.timelineSegments = [
            TimelineSegment(id: originalID, sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 10), text: "Original", subtitles: [])
        ]

        vm.splitAtPlayhead(composedTime: 5.0)
        XCTAssertEqual(vm.timelineSegments.count, 2)

        vm.undo()
        XCTAssertEqual(vm.timelineSegments.count, 1)
        XCTAssertEqual(vm.timelineSegments[0].id, originalID)
    }

    func test_restoreCheckpoint_historyIndexZero_restoresLatestCheckpointState() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)

        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 10), text: "Original", subtitles: [])
        ]

        vm.splitAtPlayhead(composedTime: 5.0)
        vm.setSegmentSpeed(at: 0, rate: 2.0)

        XCTAssertEqual(vm.timelineSegments.count, 2)
        XCTAssertEqual(vm.timelineSegments[0].normalizedSpeedRate, 2.0, accuracy: 0.001)

        let restored = vm.restoreCheckpoint(historyIndex: 0)

        XCTAssertEqual(restored?.label, "Change speed")
        XCTAssertEqual(vm.timelineSegments.count, 2)
        XCTAssertEqual(vm.timelineSegments[0].normalizedSpeedRate, 1.0, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[1].normalizedSpeedRate, 1.0, accuracy: 0.001)
    }

    // MARK: - Global undo coverage (Cmd+Z must revert every project mutation)

    /// Seed a ViewModel + source record with a single full-length
    /// primary segment. Exposed to each coverage test so every case
    /// starts from the same known state.
    private func makeVMWithPrimarySegment() -> (vm: MediaCoreViewModel, record: MediaAssetRecord) {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: record.id,
                range: TimeRange(startSeconds: 0, endSeconds: 10),
                text: "Original",
                subtitles: []
            )
        ]
        return (vm, record)
    }

    func test_swapAlternativeTake_swapsInAlternateAndDemotesPrevious() {
        let (vm, record) = makeVMWithPrimarySegment()
        let alt = AlternativeTake(
            sourceVideoID: record.id,
            startSeconds: 20,
            endSeconds: 26,
            text: "alternate",
            reason: "重启重复"
        )
        // Attach alternate to the primary segment.
        vm.timelineSegments[0].alternatives = [alt]
        let primaryID = vm.timelineSegments[0].id

        vm.swapAlternativeTake(segmentID: primaryID, takeID: alt.id)

        XCTAssertEqual(vm.timelineSegments.count, 1)
        XCTAssertEqual(vm.timelineSegments[0].range.startSeconds, 20)
        XCTAssertEqual(vm.timelineSegments[0].range.endSeconds, 26)
        XCTAssertEqual(vm.timelineSegments[0].text, "alternate")
        XCTAssertEqual(vm.timelineSegments[0].alternatives.count, 1)
        let demoted = vm.timelineSegments[0].alternatives[0]
        XCTAssertEqual(demoted.startSeconds, 0)
        XCTAssertEqual(demoted.endSeconds, 10)
        XCTAssertEqual(demoted.text, "Original")
        XCTAssertEqual(demoted.reason, "重启重复")
    }

    func test_swapAlternativeTake_isUndoable() {
        let (vm, record) = makeVMWithPrimarySegment()
        let alt = AlternativeTake(
            sourceVideoID: record.id,
            startSeconds: 30,
            endSeconds: 35,
            text: "alt",
            reason: nil
        )
        vm.timelineSegments[0].alternatives = [alt]
        let primaryID = vm.timelineSegments[0].id

        vm.swapAlternativeTake(segmentID: primaryID, takeID: alt.id)
        XCTAssertEqual(vm.timelineSegments[0].text, "alt")

        vm.undo()
        XCTAssertEqual(vm.timelineSegments[0].text, "Original")
        XCTAssertEqual(vm.timelineSegments[0].range.startSeconds, 0)
        XCTAssertEqual(vm.timelineSegments[0].range.endSeconds, 10)
    }

    func test_swapAlternativeTake_ignoresUnknownSegment() {
        let (vm, _) = makeVMWithPrimarySegment()
        let before = vm.timelineSegments
        vm.swapAlternativeTake(segmentID: UUID(), takeID: UUID())
        XCTAssertEqual(vm.timelineSegments, before)
    }

    func test_undo_revertsDragDroppedPrimarySegment() {
        let (vm, _) = makeVMWithPrimarySegment()
        let second = makeRecord()
        vm.records.append(second)

        vm.insertMediaAsPrimary(mediaID: second.id, at: vm.timelineSegments.count)
        XCTAssertEqual(vm.timelineSegments.count, 2)

        vm.undo()
        XCTAssertEqual(vm.timelineSegments.count, 1, "insertMediaAsPrimary must be undoable")
    }

    func test_undo_revertsInsertedBRollOverlay() {
        let (vm, record) = makeVMWithPrimarySegment()

        vm.insertBRollOverlay(mediaID: record.id, at: 1.0, duration: 2.0)
        XCTAssertEqual(vm.project.overlayTracks.count, 1)

        vm.undo()
        XCTAssertEqual(vm.project.overlayTracks.count, 0, "insertBRollOverlay must be undoable")
    }

    func test_setOverlayPlacementOffset_updatesPositionAndIsUndoable() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            XCTFail("expected an overlay segment")
            return
        }
        XCTAssertEqual(vm.project.overlayTracks.first?.segments.first?.placementOffset ?? -1, 0, accuracy: 0.001)

        vm.setOverlayPlacementOffset(segmentID: segID, composedStart: 3.75)
        XCTAssertEqual(vm.project.overlayTracks.first?.segments.first?.placementOffset ?? -1, 3.75, accuracy: 0.001)

        vm.undo()
        XCTAssertEqual(vm.project.overlayTracks.first?.segments.first?.placementOffset ?? -1, 0, accuracy: 0.001,
                       "setOverlayPlacementOffset must be undoable")
    }

    func test_setOverlayPlacementOffset_clampsNegativeToZero() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 2.0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            XCTFail("expected an overlay segment")
            return
        }

        vm.setOverlayPlacementOffset(segmentID: segID, composedStart: -5.0)
        XCTAssertEqual(vm.project.overlayTracks.first?.segments.first?.placementOffset ?? -1, 0, accuracy: 0.001)
    }

    func test_setOverlayPlacementOffset_withUnknownID_isNoOp() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 2.0, duration: 2.0)
        let before = vm.project
        vm.setOverlayPlacementOffset(segmentID: UUID(), composedStart: 9.9)
        XCTAssertEqual(vm.project, before, "unknown segment ID must not mutate project")
    }

    // MARK: - trimOverlaySegment

    /// Utility: materialize an image-kind record for image-overlay tests.
    /// Matches the "no analysis duration" shape real image imports have.
    private func makeImageRecord(id: UUID = UUID()) -> MediaAssetRecord {
        MediaAssetRecord(
            id: id,
            sourcePath: "/tmp/\(id.uuidString).png",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "img"),
            status: .ready,
            analysis: nil,
            derived: DerivedAssetState(proxyRelativePath: nil, thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            kind: .image
        )
    }

    func test_trimOverlaySegment_imageTrailingEdgeGrows() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        let videoRecord = makeRecord()
        let imageRecord = makeImageRecord()
        vm.records = [videoRecord, imageRecord]
        vm.select(recordID: videoRecord.id)
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: videoRecord.id,
                range: TimeRange(startSeconds: 0, endSeconds: 30),
                text: "",
                subtitles: []
            )
        ]
        // Default image duration is 4s.
        vm.insertBRollOverlay(mediaID: imageRecord.id, at: 1.0, duration: 4.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            return XCTFail("expected overlay segment")
        }

        // Trailing edge: target composed-time 11s → duration 10s.
        vm.trimOverlaySegment(segmentID: segID, edge: .trailing, composedEdgeTime: 11.0)

        let seg = vm.project.overlayTracks.first!.segments.first!
        XCTAssertEqual(seg.placementOffset ?? -1, 1.0, accuracy: 0.001, "trailing trim keeps left edge pinned")
        XCTAssertEqual(seg.durationSeconds, 10.0, accuracy: 0.001, "image can grow freely")

        vm.undo()
        let restored = vm.project.overlayTracks.first!.segments.first!
        XCTAssertEqual(restored.durationSeconds, 4.0, accuracy: 0.001, "trim must be undoable")
    }

    func test_trimOverlaySegment_imageLeadingEdgePinsRightEdge() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        let videoRecord = makeRecord()
        let imageRecord = makeImageRecord()
        vm.records = [videoRecord, imageRecord]
        vm.select(recordID: videoRecord.id)
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: videoRecord.id,
                range: TimeRange(startSeconds: 0, endSeconds: 30),
                text: "",
                subtitles: []
            )
        ]
        // Image at 5..9 (4s duration).
        vm.insertBRollOverlay(mediaID: imageRecord.id, at: 5.0, duration: 4.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            return XCTFail("expected overlay segment")
        }
        let originalRightEdge = 9.0

        // Leading edge dragged left to composed-time 3s → duration 6s,
        // right edge should stay pinned at 9s.
        vm.trimOverlaySegment(segmentID: segID, edge: .leading, composedEdgeTime: 3.0)

        let seg = vm.project.overlayTracks.first!.segments.first!
        XCTAssertEqual(seg.placementOffset ?? -1, 3.0, accuracy: 0.001)
        XCTAssertEqual(seg.durationSeconds, 6.0, accuracy: 0.001)
        XCTAssertEqual((seg.placementOffset ?? 0) + seg.durationSeconds, originalRightEdge, accuracy: 0.001,
                       "leading-edge trim must keep right edge pinned")
    }

    func test_trimOverlaySegment_videoTrailingEdgeClampsToSource() {
        let (vm, videoRecord) = makeVMWithPrimarySegment()
        // B-roll video has 300s source duration (see makeRecord).
        vm.insertBRollOverlay(mediaID: videoRecord.id, at: 0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            return XCTFail("expected overlay segment")
        }
        // Segment defaults range.start at 0 for B-roll; trailing edge at
        // 500s exceeds the 300s source. Clamp to 300s duration.
        vm.trimOverlaySegment(segmentID: segID, edge: .trailing, composedEdgeTime: 500.0)

        let seg = vm.project.overlayTracks.first!.segments.first!
        XCTAssertEqual(seg.durationSeconds, 300.0, accuracy: 0.01,
                       "video B-roll must clamp to source duration")
    }

    func test_trimOverlaySegment_videoLeadingEdgeClampsAtSourceStart() {
        let (vm, videoRecord) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: videoRecord.id, at: 10.0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            return XCTFail("expected overlay segment")
        }
        // range.start starts at 0 for this B-roll insert, so leading edge
        // can't grow at all (no preroll available). Even though composed
        // start is 10.0, we can't pull range.start below 0. The trim
        // must clamp to duration == original sourceSpan.
        vm.trimOverlaySegment(segmentID: segID, edge: .leading, composedEdgeTime: 0.0)

        let seg = vm.project.overlayTracks.first!.segments.first!
        XCTAssertEqual(seg.range.startSeconds, 0, accuracy: 0.001, "range.start clamped at 0")
        // Duration should equal the original 2s (can't grow leading),
        // placementOffset shifted to pin the right edge at 12s.
        XCTAssertEqual(seg.durationSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(seg.placementOffset ?? 0, 10.0, accuracy: 0.001)
    }

    func test_trimOverlaySegment_enforcesMinDuration() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        let imageRecord = makeImageRecord()
        vm.records = [imageRecord]
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 10),
                text: "",
                subtitles: []
            )
        ]
        vm.insertBRollOverlay(mediaID: imageRecord.id, at: 2.0, duration: 4.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            return XCTFail("expected overlay segment")
        }
        // Trailing edge all the way back to the left edge must not
        // produce a 0-duration segment.
        vm.trimOverlaySegment(segmentID: segID, edge: .trailing, composedEdgeTime: 2.0)
        let seg = vm.project.overlayTracks.first!.segments.first!
        XCTAssertGreaterThanOrEqual(seg.durationSeconds, 0.09,
                                    "trim must enforce minimum pill duration")
    }

    func test_trimOverlaySegment_withUnknownID_isNoOp() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        let before = vm.project
        vm.trimOverlaySegment(segmentID: UUID(), edge: .trailing, composedEdgeTime: 100)
        XCTAssertEqual(vm.project, before, "unknown segment ID must not mutate project")
    }

    func test_setPiPLayout_appliesAndIsUndoable() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            XCTFail("expected an overlay segment")
            return
        }
        XCTAssertNil(vm.project.overlayTracks.first?.segments.first?.pipLayout)

        var layout = PiPLayout.default
        layout.corner = .topRight
        layout.shape = .circle
        vm.setPiPLayout(segmentID: segID, layout: layout)

        let applied = vm.project.overlayTracks.first?.segments.first?.pipLayout
        XCTAssertEqual(applied?.corner, .topRight)
        XCTAssertEqual(applied?.shape, .circle)

        vm.undo()
        XCTAssertNil(vm.project.overlayTracks.first?.segments.first?.pipLayout,
                     "setPiPLayout must be undoable")
    }

    func test_setPiPLayout_nilClearsLayout() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            XCTFail("expected an overlay segment")
            return
        }

        vm.setPiPLayout(segmentID: segID, layout: .default)
        XCTAssertNotNil(vm.project.overlayTracks.first?.segments.first?.pipLayout)

        vm.setPiPLayout(segmentID: segID, layout: nil)
        XCTAssertNil(vm.project.overlayTracks.first?.segments.first?.pipLayout)
    }

    func test_setPiPLayout_withUnknownID_isNoOp() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        let before = vm.project
        vm.setPiPLayout(segmentID: UUID(), layout: .default)
        XCTAssertEqual(vm.project, before)
    }

    func test_applyPiPSuggestion_writesLayoutAndRemovesSuggestion() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            XCTFail("expected an overlay segment")
            return
        }

        // Simulate the analyzer having emitted a suggestion for this
        // overlay. We bypass the async scanner because it requires a
        // real video file + Vision; the pure apply-path is all we
        // need to cover here.
        var layout = PiPLayout.default
        layout.corner = .topLeft
        layout.shape = .circle
        let suggestion = PiPSuggestion(
            overlaySegmentID: segID,
            layout: layout,
            confidence: 0.82
        )
        vm.pipSuggestions = [suggestion]

        vm.applyPiPSuggestion(id: suggestion.id)

        XCTAssertTrue(vm.pipSuggestions.isEmpty,
                      "applying a suggestion must remove it from the list")
        let applied = vm.project.overlayTracks.first?.segments.first?.pipLayout
        XCTAssertEqual(applied?.corner, .topLeft)
        XCTAssertEqual(applied?.shape, .circle)
    }

    func test_dismissPiPSuggestion_removesWithoutMutatingProject() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            XCTFail("expected an overlay segment")
            return
        }
        let suggestion = PiPSuggestion(
            overlaySegmentID: segID,
            layout: .default,
            confidence: 0.7
        )
        vm.pipSuggestions = [suggestion]
        let beforeProject = vm.project

        vm.dismissPiPSuggestion(id: suggestion.id)

        XCTAssertTrue(vm.pipSuggestions.isEmpty)
        XCTAssertEqual(vm.project, beforeProject,
                       "dismiss must not touch the project")
    }

    func test_applyPiPSuggestion_unknownID_isNoOp() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        let before = vm.project
        vm.applyPiPSuggestion(id: UUID())
        XCTAssertEqual(vm.project, before)
    }

    // MARK: - runAutoPiPAnalysis (chat-agent auto_pip tool surface)

    func test_runAutoPiPAnalysis_withNoOverlays_returnsZeroAttempted() async {
        let (vm, _) = makeVMWithPrimarySegment()
        let result = await vm.runAutoPiPAnalysis()
        XCTAssertEqual(result.attempted, 0)
        XCTAssertEqual(result.applied, 0)
        XCTAssertTrue(result.appliedIDs.isEmpty)
    }

    func test_runAutoPiPAnalysis_skipsOverlaysThatAlreadyHavePiPLayout() async {
        // Overlays that already carry a pipLayout must NOT be re-
        // analyzed — the chat tool is intended to fill in missing
        // layouts, not overwrite user/AI choices.
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            XCTFail("expected an overlay segment")
            return
        }
        vm.setPiPLayout(segmentID: segID, layout: .default)
        let result = await vm.runAutoPiPAnalysis()
        XCTAssertEqual(result.attempted, 0,
                       "overlays with an existing pipLayout must be skipped")
        XCTAssertEqual(result.applied, 0)
    }

    // MARK: - setPiPGeometry + snapPiPToNearestCorner

    func test_setPiPGeometry_writesAllThreeFieldsInOneRevision() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            XCTFail("expected an overlay segment")
            return
        }
        // Seed an initial PiP layout so the geometry write has a
        // baseline to modify.
        vm.setPiPLayout(segmentID: segID, layout: .default)
        let beforeRevisions = vm.revisions.count

        vm.setPiPGeometry(
            segmentID: segID,
            corner: .topLeft,
            insetFraction: 0.15,
            sizeFraction: 0.3
        )

        let applied = vm.project.overlayTracks.first?.segments.first?.pipLayout
        XCTAssertEqual(applied?.corner, .topLeft)
        XCTAssertEqual(applied?.insetFraction ?? 0, 0.15, accuracy: 0.0001)
        XCTAssertEqual(applied?.sizeFraction ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(vm.revisions.count, beforeRevisions + 1,
                       "geometry write must push exactly one revision")

        vm.undo()
        let reverted = vm.project.overlayTracks.first?.segments.first?.pipLayout
        XCTAssertEqual(reverted?.corner, PiPLayout.default.corner)
        XCTAssertEqual(reverted?.insetFraction ?? 0, PiPLayout.default.insetFraction, accuracy: 0.0001)
        XCTAssertEqual(reverted?.sizeFraction ?? 0, PiPLayout.default.sizeFraction, accuracy: 0.0001)
    }

    func test_snapPiPToNearestCorner_picksBottomRightForLowerRightRect() {
        let canvas = CGSize(width: 1920, height: 1080)
        let rectSize = CGSize(width: 300, height: 300)
        // Rect sitting in the lower-right quadrant, 40pt from the edge.
        let origin = CGPoint(x: 1920 - 300 - 40, y: 1080 - 300 - 40)
        let snap = MediaCoreViewModel.snapPiPToNearestCorner(
            rectOrigin: origin,
            rectSize: rectSize,
            canvasSize: canvas
        )
        XCTAssertEqual(snap.corner, .bottomRight)
        XCTAssertEqual(snap.insetFraction, 40.0 / 1080.0, accuracy: 0.001)
    }

    func test_snapPiPToNearestCorner_picksTopLeftForUpperLeftRect() {
        let canvas = CGSize(width: 1920, height: 1080)
        let snap = MediaCoreViewModel.snapPiPToNearestCorner(
            rectOrigin: CGPoint(x: 50, y: 30),
            rectSize: CGSize(width: 200, height: 200),
            canvasSize: canvas
        )
        XCTAssertEqual(snap.corner, .topLeft)
        // Uses max of x/y insets → 50px on a 1080 canvas ≈ 0.0463.
        XCTAssertEqual(snap.insetFraction, 50.0 / 1080.0, accuracy: 0.001)
    }

    func test_snapPiPToNearestCorner_clampsInsetToMax() {
        let canvas = CGSize(width: 1920, height: 1080)
        // Rect far from every corner — should clamp at maxInsetFraction.
        let snap = MediaCoreViewModel.snapPiPToNearestCorner(
            rectOrigin: CGPoint(x: 700, y: 400),
            rectSize: CGSize(width: 200, height: 200),
            canvasSize: canvas
        )
        XCTAssertLessThanOrEqual(snap.insetFraction, PiPLayout.maxInsetFraction + 0.0001)
    }

    func test_setSegmentVideoHidden_primaryToggleIsUndoable() {
        let (vm, _) = makeVMWithPrimarySegment()
        guard let segID = vm.timelineSegments.first?.id else {
            XCTFail("expected a primary segment")
            return
        }
        XCTAssertFalse(vm.timelineSegments[0].isVideoHidden)

        vm.setSegmentVideoHidden(segmentID: segID, hidden: true)
        XCTAssertTrue(vm.timelineSegments[0].isVideoHidden)

        vm.undo()
        XCTAssertFalse(vm.timelineSegments[0].isVideoHidden,
                       "hide-video must be undoable on primary segments")
    }

    func test_setSegmentVideoHidden_overlayToggleIsUndoable() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.insertBRollOverlay(mediaID: record.id, at: 0, duration: 2.0)
        guard let segID = vm.project.overlayTracks.first?.segments.first?.id else {
            XCTFail("expected an overlay segment")
            return
        }

        vm.setSegmentVideoHidden(segmentID: segID, hidden: true)
        XCTAssertEqual(vm.project.overlayTracks.first?.segments.first?.isVideoHidden, true)

        vm.undo()
        XCTAssertEqual(vm.project.overlayTracks.first?.segments.first?.isVideoHidden, false,
                       "hide-video must be undoable on overlay segments")
    }

    func test_toggleSegmentAudioMuted_primaryFlipsVolumeLevel() {
        let (vm, _) = makeVMWithPrimarySegment()
        guard let segID = vm.timelineSegments.first?.id else {
            XCTFail("expected a primary segment")
            return
        }
        XCTAssertGreaterThan(vm.timelineSegments[0].volumeLevel, 0)

        vm.toggleSegmentAudioMuted(segmentID: segID)
        XCTAssertEqual(vm.timelineSegments[0].volumeLevel, 0, accuracy: 0.001)

        vm.toggleSegmentAudioMuted(segmentID: segID)
        XCTAssertEqual(vm.timelineSegments[0].volumeLevel, 1, accuracy: 0.001)
    }

    func test_toggleSegmentAudioMuted_unknownIDIsNoOp() {
        let (vm, _) = makeVMWithPrimarySegment()
        let before = vm.project
        vm.toggleSegmentAudioMuted(segmentID: UUID())
        XCTAssertEqual(vm.project, before)
    }

    // MARK: - Detach Audio

    func test_detachAudio_mutesV1AndCreatesLinkedAuxSegment() {
        let (vm, _) = makeVMWithPrimarySegment()
        guard let v1ID = vm.timelineSegments.first?.id else {
            XCTFail("expected V1 segment"); return
        }
        XCTAssertEqual(vm.project.audioTracks.count, 0)

        vm.detachAudio(segmentID: v1ID)

        XCTAssertEqual(vm.timelineSegments[0].volumeLevel, 0, accuracy: 0.001)
        XCTAssertNotNil(vm.timelineSegments[0].linkedSegmentID)

        XCTAssertEqual(vm.project.audioTracks.count, 1)
        let auxTrack = vm.project.audioTracks[0]
        XCTAssertEqual(auxTrack.name, MediaCoreViewModel.detachedAudioTrackName)
        XCTAssertEqual(auxTrack.segments.count, 1)
        let aux = auxTrack.segments[0]
        XCTAssertEqual(aux.linkedSegmentID, v1ID)
        XCTAssertEqual(vm.timelineSegments[0].linkedSegmentID, aux.id)
        XCTAssertEqual(aux.placementOffset ?? -1, 0, accuracy: 0.001, "aux should anchor at V1 composed start")
        XCTAssertEqual(aux.range.startSeconds, vm.timelineSegments[0].range.startSeconds)
        XCTAssertEqual(aux.range.endSeconds, vm.timelineSegments[0].range.endSeconds)
        XCTAssertEqual(aux.volumeLevel, 1.0, accuracy: 0.001)
    }

    func test_detachAudio_secondClipReusesDetachedTrack() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.timelineSegments.append(TimelineSegment(
            id: UUID(),
            sourceVideoID: record.id,
            range: TimeRange(startSeconds: 10, endSeconds: 20),
            text: "Second",
            subtitles: []
        ))

        vm.detachAudio(segmentID: vm.timelineSegments[0].id)
        vm.detachAudio(segmentID: vm.timelineSegments[1].id)

        XCTAssertEqual(vm.project.audioTracks.count, 1, "both detaches share one A2 lane")
        XCTAssertEqual(vm.project.audioTracks[0].segments.count, 2)
        // Second aux segment should anchor at end of first V1 clip.
        let secondAux = vm.project.audioTracks[0].segments[1]
        XCTAssertEqual(secondAux.placementOffset ?? -1, 10, accuracy: 0.001)
    }

    func test_detachAudio_isIdempotentForAlreadyDetachedSegment() {
        let (vm, _) = makeVMWithPrimarySegment()
        let v1ID = vm.timelineSegments[0].id
        vm.detachAudio(segmentID: v1ID)
        let stateAfterFirst = vm.project

        vm.detachAudio(segmentID: v1ID)

        XCTAssertEqual(vm.project, stateAfterFirst, "second detach is a no-op")
    }

    func test_reattachAudio_fromV1SideRestoresVolumeAndRemovesAux() {
        let (vm, _) = makeVMWithPrimarySegment()
        let v1ID = vm.timelineSegments[0].id
        vm.detachAudio(segmentID: v1ID)
        XCTAssertEqual(vm.project.audioTracks.count, 1)

        vm.reattachAudio(segmentID: v1ID)

        XCTAssertEqual(vm.timelineSegments[0].volumeLevel, 1.0, accuracy: 0.001)
        XCTAssertNil(vm.timelineSegments[0].linkedSegmentID)
        XCTAssertEqual(vm.project.audioTracks.count, 0, "empty detached-audio track should be removed")
    }

    func test_reattachAudio_fromAuxSideWorksToo() {
        let (vm, _) = makeVMWithPrimarySegment()
        let v1ID = vm.timelineSegments[0].id
        vm.detachAudio(segmentID: v1ID)
        let auxID = vm.project.audioTracks[0].segments[0].id

        vm.reattachAudio(segmentID: auxID)

        XCTAssertEqual(vm.timelineSegments[0].volumeLevel, 1.0, accuracy: 0.001)
        XCTAssertNil(vm.timelineSegments[0].linkedSegmentID)
        XCTAssertEqual(vm.project.audioTracks.count, 0)
    }

    func test_detachAudio_undoRestoresPreDetachState() {
        let (vm, _) = makeVMWithPrimarySegment()
        let v1ID = vm.timelineSegments[0].id
        let before = vm.project

        vm.detachAudio(segmentID: v1ID)
        vm.undo()

        XCTAssertEqual(vm.project, before)
    }

    func test_persistableSegment_roundTripsLinkedSegmentID() throws {
        var seg = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 5),
            text: "t",
            subtitles: []
        )
        seg.linkedSegmentID = UUID()

        let persistable = EditorRevision.PersistableSegment(from: seg)
        let data = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(EditorRevision.PersistableSegment.self, from: data)
        let restored = decoded.toTimelineSegment()

        XCTAssertEqual(restored.linkedSegmentID, seg.linkedSegmentID)
    }

    // MARK: - Detach Audio — link propagation during edits

    /// Build a VM with two 10s V1 segments and detach audio on clip 0.
    /// Returns the VM plus stable references for the test.
    private func makeVMWithDetachedAudio() -> (vm: MediaCoreViewModel, v1ID: UUID, auxID: UUID) {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.timelineSegments.append(TimelineSegment(
            id: UUID(),
            sourceVideoID: record.id,
            range: TimeRange(startSeconds: 10, endSeconds: 20),
            text: "Second",
            subtitles: []
        ))
        let v1ID = vm.timelineSegments[0].id
        vm.detachAudio(segmentID: v1ID)
        let auxID = vm.project.audioTracks[0].segments[0].id
        return (vm, v1ID, auxID)
    }

    func test_deleteSegment_cascadesToLinkedAuxSegment() {
        let (vm, v1ID, _) = makeVMWithDetachedAudio()
        XCTAssertEqual(vm.project.audioTracks.first?.segments.count ?? 0, 1)

        let v1Idx = vm.timelineSegments.firstIndex(where: { $0.id == v1ID })!
        vm.deleteSegment(at: v1Idx)

        XCTAssertEqual(vm.project.audioTracks.count, 0, "empty detached-audio track removed after cascade")
    }

    func test_deleteSelectedSegments_cascadesForEachLinkedV1() {
        let (vm, v1ID, _) = makeVMWithDetachedAudio()
        // Detach the second V1 clip too.
        let v1TwoID = vm.timelineSegments[1].id
        vm.detachAudio(segmentID: v1TwoID)
        XCTAssertEqual(vm.project.audioTracks[0].segments.count, 2)

        vm.selectAllSegments()
        vm.deleteSelectedSegments()

        XCTAssertEqual(vm.timelineSegments.count, 0)
        XCTAssertEqual(vm.project.audioTracks.count, 0)
        _ = v1ID
    }

    func test_moveSegment_updatesLinkedAuxPlacementOffset() {
        let (vm, v1ID, auxID) = makeVMWithDetachedAudio()
        // Clip 0's composed start is 0. Move it to position 1 — its new
        // composed start should be 10 (duration of clip previously at 0).
        XCTAssertEqual(vm.project.audioTracks[0].segments[0].placementOffset ?? -1, 0, accuracy: 0.001)

        vm.moveSegment(from: IndexSet(integer: 0), to: 2)

        XCTAssertEqual(vm.timelineSegments[1].id, v1ID, "V1 should now be at index 1")
        let updatedAux = vm.project.audioTracks[0].segments.first(where: { $0.id == auxID })!
        XCTAssertEqual(updatedAux.placementOffset ?? -1, 10, accuracy: 0.001,
                       "aux placementOffset should follow V1's new composed start")
    }

    func test_endTrim_syncsLinkedAuxRangeAndOffset() {
        let (vm, v1ID, auxID) = makeVMWithDetachedAudio()
        let v1Idx = vm.timelineSegments.firstIndex(where: { $0.id == v1ID })!

        vm.beginTrim(index: v1Idx)
        vm.liveTrim(index: v1Idx, edge: .trailing, deltaSeconds: -3) // 10s → 7s
        vm.endTrim(index: v1Idx)

        let aux = vm.project.audioTracks[0].segments.first(where: { $0.id == auxID })!
        XCTAssertEqual(aux.range.endSeconds, vm.timelineSegments[v1Idx].range.endSeconds, accuracy: 0.001,
                       "aux range should follow V1 trim")
    }

    func test_splitAtPlayhead_splitsLinkedAuxInParallel() {
        let (vm, v1ID, auxID) = makeVMWithDetachedAudio()
        // V1 clip 0 is 10s long at composed t=0..10. Split at t=4.
        vm.splitAtPlayhead(composedTime: 4.0)

        // We should now have 3 V1 segs (left-half, right-half, second clip).
        XCTAssertEqual(vm.timelineSegments.count, 3)
        XCTAssertEqual(vm.timelineSegments[0].range.endSeconds, 4.0, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[1].range.startSeconds, 4.0, accuracy: 0.001)
        // Both halves should still be linked.
        XCTAssertNotNil(vm.timelineSegments[0].linkedSegmentID)
        XCTAssertNotNil(vm.timelineSegments[1].linkedSegmentID)
        XCTAssertNotEqual(vm.timelineSegments[0].linkedSegmentID, vm.timelineSegments[1].linkedSegmentID)

        // Aux track should now have 2 audio segments covering the same ranges.
        let auxes = vm.project.audioTracks[0].segments
        XCTAssertEqual(auxes.count, 2)
        XCTAssertEqual(auxes[0].range.endSeconds, 4.0, accuracy: 0.001)
        XCTAssertEqual(auxes[1].range.startSeconds, 4.0, accuracy: 0.001)
        // Left aux keeps the original id.
        XCTAssertEqual(auxes[0].id, auxID)
        // Each aux half is linked to its paired V1 half.
        XCTAssertEqual(auxes[0].linkedSegmentID, vm.timelineSegments[0].id)
        XCTAssertEqual(auxes[1].linkedSegmentID, vm.timelineSegments[1].id)
        XCTAssertEqual(vm.timelineSegments[0].linkedSegmentID, auxes[0].id)
        XCTAssertEqual(vm.timelineSegments[1].linkedSegmentID, auxes[1].id)
    }

    func test_deleteAuxAudioSegment_linked_reattaches() {
        let (vm, v1ID, auxID) = makeVMWithDetachedAudio()

        vm.deleteAuxAudioSegment(id: auxID)

        // Linked case must unmute V1 and drop the link (equivalent to reattach).
        let v1 = vm.timelineSegments.first(where: { $0.id == v1ID })!
        XCTAssertEqual(v1.volumeLevel, 1.0, accuracy: 0.001)
        XCTAssertNil(v1.linkedSegmentID)
        XCTAssertEqual(vm.project.audioTracks.count, 0)
    }

    func test_undo_revertsAddedCrossfade() {
        let (vm, record) = makeVMWithPrimarySegment()
        // Append a second primary segment so the pair is adjacent.
        vm.timelineSegments.append(TimelineSegment(
            id: UUID(),
            sourceVideoID: record.id,
            range: TimeRange(startSeconds: 0, endSeconds: 8),
            text: "",
            subtitles: []
        ))

        vm.addCrossfade(fromIndex: 0, duration: 0.5)
        XCTAssertGreaterThan(vm.timelineSegments[0].effects.audioFadeOutDuration, 0)

        vm.undo()
        XCTAssertEqual(vm.timelineSegments[0].effects.audioFadeOutDuration, 0, accuracy: 0.001,
                       "addCrossfade must be undoable")
    }

    func test_undo_revertsTrackMuteToggle() {
        let (vm, _) = makeVMWithPrimarySegment()
        // Append an aux track so we have something non-primary to mute.
        vm.project.tracks.append(Track(kind: .audio, name: "BGM", segments: []))
        let auxID = vm.project.tracks.last!.id

        vm.toggleTrackMute(id: auxID)
        XCTAssertTrue(vm.project.tracks.first(where: { $0.id == auxID })?.isMuted ?? false)

        vm.undo()
        XCTAssertFalse(vm.project.tracks.first(where: { $0.id == auxID })?.isMuted ?? true,
                       "toggleTrackMute must be undoable")
    }

    func test_undo_revertsAuxTrackVolume() {
        let (vm, _) = makeVMWithPrimarySegment()
        // Aux audio track with one non-silent segment.
        let auxSeg = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: 5),
            text: "",
            subtitles: [],
            volumeLevel: 1.0
        )
        vm.project.tracks.append(Track(kind: .audio, name: "BGM", segments: [auxSeg]))
        let auxID = vm.project.tracks.last!.id

        vm.setAuxTrackVolume(id: auxID, volume: 0.3)
        XCTAssertEqual(vm.project.tracks.last?.segments.first?.volumeLevel ?? 0, 0.3, accuracy: 0.001)

        vm.undo()
        XCTAssertEqual(vm.project.tracks.last?.segments.first?.volumeLevel ?? 0, 1.0, accuracy: 0.001,
                       "setAuxTrackVolume must be undoable")
    }

    func test_mutateProject_skipsRevisionWhenBodyReportsNoChange() {
        let (vm, _) = makeVMWithPrimarySegment()
        let beforeCount = vm.revisions.count

        vm.mutateProject(label: "noop") { _ in false }

        XCTAssertEqual(vm.revisions.count, beforeCount,
                       "No-op mutateProject calls must not pollute the undo stack")
    }

    // MARK: - Track lock + V1 mute

    func test_toggleTrackLocked_togglesAndIsUndoable() {
        let (vm, _) = makeVMWithPrimarySegment()
        let v1ID = vm.project.tracks.first(where: { $0.kind == .video })!.id

        vm.toggleTrackLocked(id: v1ID)
        XCTAssertTrue(vm.isTrackLocked(id: v1ID))

        vm.undo()
        XCTAssertFalse(vm.isTrackLocked(id: v1ID),
                       "toggleTrackLocked must be undoable")
    }

    func test_toggleTrackMute_allowsV1() {
        let (vm, _) = makeVMWithPrimarySegment()
        let v1ID = vm.project.tracks.first(where: { $0.kind == .video })!.id

        vm.toggleTrackMute(id: v1ID)
        XCTAssertTrue(vm.project.tracks.first(where: { $0.id == v1ID })?.isMuted ?? false,
                      "V1 mute must now be allowed (used for silencing primary audio)")
    }

    func test_moveSegment_lockedPrimaryNoops() {
        let (vm, record) = makeVMWithPrimarySegment()
        vm.timelineSegments.append(TimelineSegment(
            id: UUID(),
            sourceVideoID: record.id,
            range: TimeRange(startSeconds: 0, endSeconds: 5),
            text: "",
            subtitles: []
        ))
        let firstID = vm.timelineSegments[0].id
        let v1ID = vm.project.tracks.first(where: { $0.kind == .video })!.id

        vm.toggleTrackLocked(id: v1ID)
        vm.moveSegment(from: IndexSet(integer: 0), to: 2)

        XCTAssertEqual(vm.timelineSegments[0].id, firstID,
                       "Move must be a no-op on a locked primary track")
    }

    func test_deleteSegment_lockedPrimaryNoops() {
        let (vm, _) = makeVMWithPrimarySegment()
        let v1ID = vm.project.tracks.first(where: { $0.kind == .video })!.id

        vm.toggleTrackLocked(id: v1ID)
        vm.deleteSegment(at: 0)

        XCTAssertEqual(vm.timelineSegments.count, 1,
                       "Delete must be a no-op on a locked primary track")
    }

    func test_splitAtPlayhead_lockedPrimaryNoops() {
        let (vm, _) = makeVMWithPrimarySegment()
        let v1ID = vm.project.tracks.first(where: { $0.kind == .video })!.id

        vm.toggleTrackLocked(id: v1ID)
        vm.splitAtPlayhead(composedTime: 5)

        XCTAssertEqual(vm.timelineSegments.count, 1,
                       "Split must be a no-op on a locked primary track")
    }

    func test_setPlaybackRate_updatesRate() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy)

        vm.setPlaybackRate(2.0)
        XCTAssertEqual(vm.playbackRate, 2.0)
    }

    func test_markInOutPoints_setsAndClears() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy)

        vm.markInPoint(at: 3.0)
        XCTAssertEqual(vm.inPoint, 3.0)
        XCTAssertNil(vm.outPoint)

        vm.markOutPoint(at: 7.0)
        XCTAssertEqual(vm.outPoint, 7.0)

        // Setting in after out should clear out
        vm.markInPoint(at: 8.0)
        XCTAssertNil(vm.outPoint)

        vm.clearInOutPoints()
        XCTAssertNil(vm.inPoint)
        XCTAssertNil(vm.outPoint)
    }

    func test_canExport_usesTimelineSegments_notCopilot() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let record = makeRecord()
        vm.records = [record]
        vm.select(recordID: record.id)

        // No segments = can't export
        vm.timelineSegments = []
        XCTAssertFalse(vm.canExport)

        // With segments = can export
        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 5), text: "", subtitles: [])
        ]
        XCTAssertTrue(vm.canExport)
    }

    // MARK: - Segment Effects

    func test_rotateSegment_cycles90Degrees() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        vm.records = [makeRecord()]
        vm.select(recordID: vm.records[0].id)

        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 5), text: "", subtitles: [])
        ]

        vm.rotateSegment(at: 0)
        XCTAssertEqual(vm.timelineSegments[0].effects.rotation, 90)

        vm.rotateSegment(at: 0)
        XCTAssertEqual(vm.timelineSegments[0].effects.rotation, 180)

        vm.rotateSegment(at: 0)
        XCTAssertEqual(vm.timelineSegments[0].effects.rotation, 270)

        vm.rotateSegment(at: 0)
        XCTAssertEqual(vm.timelineSegments[0].effects.rotation, 0)
    }

    func test_flipSegment_toggles() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        vm.records = [makeRecord()]
        vm.select(recordID: vm.records[0].id)

        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 5), text: "", subtitles: [])
        ]

        vm.flipSegmentHorizontal(at: 0)
        XCTAssertTrue(vm.timelineSegments[0].effects.flipHorizontal)

        vm.flipSegmentHorizontal(at: 0)
        XCTAssertFalse(vm.timelineSegments[0].effects.flipHorizontal)
    }

    func test_setSegmentColor_clampsValues() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        vm.records = [makeRecord()]
        vm.select(recordID: vm.records[0].id)

        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 5), text: "", subtitles: [])
        ]

        vm.setSegmentColor(at: 0, brightness: 0.5, contrast: 1.5, saturation: 0.3)
        XCTAssertEqual(vm.timelineSegments[0].effects.brightness, 0.5, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[0].effects.contrast, 1.5, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[0].effects.saturation, 0.3, accuracy: 0.001)

        // Test clamping
        vm.setSegmentColor(at: 0, brightness: -5)
        XCTAssertEqual(vm.timelineSegments[0].effects.brightness, -1, accuracy: 0.001)

        vm.setSegmentColor(at: 0, contrast: 10)
        XCTAssertEqual(vm.timelineSegments[0].effects.contrast, 2, accuracy: 0.001)
    }

    func test_setSegmentAudioFade_clampsToHalfDuration() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        vm.records = [makeRecord()]
        vm.select(recordID: vm.records[0].id)

        // 4 second segment
        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 4), text: "", subtitles: [])
        ]

        vm.setSegmentAudioFade(at: 0, fadeIn: 1.0, fadeOut: 1.5)
        XCTAssertEqual(vm.timelineSegments[0].effects.audioFadeInDuration, 1.0, accuracy: 0.001)
        XCTAssertEqual(vm.timelineSegments[0].effects.audioFadeOutDuration, 1.5, accuracy: 0.001)

        // Max fade = 2s (half of 4s)
        vm.setSegmentAudioFade(at: 0, fadeIn: 10)
        XCTAssertEqual(vm.timelineSegments[0].effects.audioFadeInDuration, 2.0, accuracy: 0.001)
    }

    func test_resetSegmentEffects_restoresDefaults() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        vm.records = [makeRecord()]
        vm.select(recordID: vm.records[0].id)

        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: UUID(), range: TimeRange(startSeconds: 0, endSeconds: 5), text: "", subtitles: [])
        ]

        vm.rotateSegment(at: 0)
        vm.setSegmentColor(at: 0, brightness: 0.5)
        vm.setSegmentAudioFade(at: 0, fadeIn: 1.0)
        XCTAssertFalse(vm.timelineSegments[0].effects.isDefault)

        vm.resetSegmentEffects(at: 0)
        XCTAssertTrue(vm.timelineSegments[0].effects.isDefault)
    }

    func test_segmentEffects_hasHelpers() {
        var effects = SegmentEffects.default
        XCTAssertTrue(effects.isDefault)
        XCTAssertFalse(effects.hasColorAdjustment)
        XCTAssertFalse(effects.hasTransform)
        XCTAssertFalse(effects.hasAudioFade)

        effects.brightness = 0.5
        XCTAssertTrue(effects.hasColorAdjustment)
        XCTAssertFalse(effects.isDefault)

        effects = .default
        effects.rotation = 90
        XCTAssertTrue(effects.hasTransform)

        effects = .default
        effects.audioFadeInDuration = 1.0
        XCTAssertTrue(effects.hasAudioFade)
    }

    // MARK: - Subtitle chunking

    func test_buildSubtitleEntries_usesWordTranscriptToChunkLongSentences() {
        // A single "sentence" covering 10s that contains many Chinese words.
        let words: [TranscriptSegment] = (0..<30).map { i in
            TranscriptSegment(
                startSeconds: Double(i) * 0.33,
                endSeconds: Double(i) * 0.33 + 0.30,
                text: "字",
                sourceVideoID: nil
            )
        }
        let sentence = [TranscriptSegment(
            startSeconds: 0,
            endSeconds: 10,
            text: String(repeating: "字", count: 30),
            sourceVideoID: nil
        )]

        let entries = MediaCoreViewModel.buildSubtitleEntries(
            for: TimeRange(startSeconds: 0, endSeconds: 10),
            from: sentence,
            wordTranscript: words
        )

        XCTAssertGreaterThan(entries.count, 1, "Long run of words should be split into multiple subtitle chunks")
        for entry in entries {
            let visible = entry.text.unicodeScalars.reduce(0) { $1.properties.isWhitespace ? $0 : $0 + 1 }
            XCTAssertLessThanOrEqual(visible, 20, "Each CJK chunk should respect the display budget")
            XCTAssertGreaterThan(entry.relativeDuration, 0)
        }
        // Chunks should be ordered and timed within the range.
        for i in 1..<entries.count {
            XCTAssertGreaterThanOrEqual(entries[i].relativeStart, entries[i - 1].relativeStart)
        }
    }

    func test_buildSubtitleEntries_splitsLongSentenceWhenWordTranscriptMissing() {
        let longChinese = "我今天要告诉大家一个非常非常长而且不停说下去的故事完全没有标点符号"
        let sentence = [TranscriptSegment(
            startSeconds: 0,
            endSeconds: 8,
            text: longChinese,
            sourceVideoID: nil
        )]

        let entries = MediaCoreViewModel.buildSubtitleEntries(
            for: TimeRange(startSeconds: 0, endSeconds: 8),
            from: sentence,
            wordTranscript: nil
        )

        XCTAssertGreaterThan(entries.count, 1)
        let totalDuration = entries.reduce(0) { $0 + $1.relativeDuration }
        XCTAssertEqual(totalDuration, 8, accuracy: 0.01)
    }

    func test_buildSubtitleEntries_shortSentenceStaysAsSingleEntry() {
        let sentence = [TranscriptSegment(
            startSeconds: 0,
            endSeconds: 1.5,
            text: "你好",
            sourceVideoID: nil
        )]

        let entries = MediaCoreViewModel.buildSubtitleEntries(
            for: TimeRange(startSeconds: 0, endSeconds: 1.5),
            from: sentence,
            wordTranscript: nil
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].text, "你好")
    }

    func test_buildSubtitleEntries_wordGapTriggersNewChunk() {
        // Two groups of words separated by a 1.2s silence; each group short.
        let words: [TranscriptSegment] = [
            TranscriptSegment(startSeconds: 0.0, endSeconds: 0.4, text: "hello", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 0.4, endSeconds: 0.8, text: "world", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 2.0, endSeconds: 2.4, text: "after", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 2.4, endSeconds: 2.8, text: "gap", sourceVideoID: nil)
        ]
        let entries = MediaCoreViewModel.buildSubtitleEntries(
            for: TimeRange(startSeconds: 0, endSeconds: 3),
            from: nil,
            wordTranscript: words
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].text, "hello world")
        XCTAssertEqual(entries[1].text, "after gap")
    }

    /// Char-level karaoke: each cue carries `wordTimings` whose
    /// concatenated text matches the cue text, and whose entry-relative
    /// times are non-negative and monotone.
    func test_buildSubtitleEntries_attachesPerCharWordTimings_forCJK() {
        // "我们今天" — 4 Chinese chars, evenly spaced.
        let words: [TranscriptSegment] = [
            TranscriptSegment(startSeconds: 1.0, endSeconds: 1.2, text: "我", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 1.2, endSeconds: 1.4, text: "们", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 1.4, endSeconds: 1.6, text: "今", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 1.6, endSeconds: 1.8, text: "天", sourceVideoID: nil)
        ]
        let entries = MediaCoreViewModel.buildSubtitleEntries(
            for: TimeRange(startSeconds: 0, endSeconds: 3),
            from: nil,
            wordTranscript: words
        )
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.text, "我们今天")
        XCTAssertNotNil(entry.wordTimings)
        guard let timings = entry.wordTimings else { return }
        XCTAssertEqual(timings.count, 4)
        XCTAssertEqual(timings.map(\.text), ["我", "们", "今", "天"])
        // Times should be entry-relative (cue starts at 1.0s absolute,
        // so the first char is at 0.0 entry-relative).
        XCTAssertEqual(timings[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(timings[0].endSeconds, 0.2, accuracy: 0.001)
        XCTAssertEqual(timings[3].startSeconds, 0.6, accuracy: 0.001)
        XCTAssertEqual(timings[3].endSeconds, 0.8, accuracy: 0.001)
        // Monotone non-negative.
        for t in timings {
            XCTAssertGreaterThanOrEqual(t.startSeconds, 0)
            XCTAssertGreaterThanOrEqual(t.endSeconds, t.startSeconds)
        }
    }

    /// 0.3s inter-character gap is the configured threshold.
    /// A gap >= 0.3s should produce a new cue.
    func test_buildSubtitleEntries_silenceGap03sBreaksCue() {
        let words: [TranscriptSegment] = [
            TranscriptSegment(startSeconds: 0.0, endSeconds: 0.2, text: "你", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 0.2, endSeconds: 0.4, text: "好", sourceVideoID: nil),
            // 0.35s silence here — over threshold (0.3s).
            TranscriptSegment(startSeconds: 0.75, endSeconds: 0.95, text: "再", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 0.95, endSeconds: 1.15, text: "见", sourceVideoID: nil)
        ]
        let entries = MediaCoreViewModel.buildSubtitleEntries(
            for: TimeRange(startSeconds: 0, endSeconds: 2),
            from: nil,
            wordTranscript: words
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].text, "你好")
        XCTAssertEqual(entries[1].text, "再见")
    }

    /// A short gap (under 0.3s threshold) should not break the cue —
    /// chars stay in the same subtitle.
    func test_buildSubtitleEntries_shortGapStaysInSameCue() {
        let words: [TranscriptSegment] = [
            TranscriptSegment(startSeconds: 0.0, endSeconds: 0.2, text: "你", sourceVideoID: nil),
            TranscriptSegment(startSeconds: 0.2, endSeconds: 0.4, text: "好", sourceVideoID: nil),
            // 0.15s gap — under threshold, should stay.
            TranscriptSegment(startSeconds: 0.55, endSeconds: 0.75, text: "啊", sourceVideoID: nil)
        ]
        let entries = MediaCoreViewModel.buildSubtitleEntries(
            for: TimeRange(startSeconds: 0, endSeconds: 1),
            from: nil,
            wordTranscript: words
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].text, "你好啊")
    }

    /// Char budget (14 visible CJK chars) must force a flush even when
    /// inter-char gaps stay under the silence threshold.
    func test_buildSubtitleEntries_budgetForcesFlush_evenWithoutGap() {
        // 20 chars at 0.1s each, no real silence — should still split.
        let words: [TranscriptSegment] = (0..<20).map { i in
            TranscriptSegment(
                startSeconds: Double(i) * 0.1,
                endSeconds: Double(i) * 0.1 + 0.09,
                text: "字",
                sourceVideoID: nil
            )
        }
        let entries = MediaCoreViewModel.buildSubtitleEntries(
            for: TimeRange(startSeconds: 0, endSeconds: 3),
            from: nil,
            wordTranscript: words
        )
        XCTAssertGreaterThan(entries.count, 1)
        for entry in entries {
            let visible = entry.text.unicodeScalars.reduce(0) { $1.properties.isWhitespace ? $0 : $0 + 1 }
            XCTAssertLessThanOrEqual(visible, 14)
        }
    }

    /// 3.5s duration cap must force a flush even when both budget and
    /// gaps are under threshold.
    func test_buildSubtitleEntries_durationCapForcesFlush() {
        // 5 chars spread over 6 seconds with no real silence.
        let words: [TranscriptSegment] = (0..<5).map { i in
            TranscriptSegment(
                startSeconds: Double(i) * 1.2,
                endSeconds: Double(i) * 1.2 + 1.0,
                text: "字",
                sourceVideoID: nil
            )
        }
        let entries = MediaCoreViewModel.buildSubtitleEntries(
            for: TimeRange(startSeconds: 0, endSeconds: 7),
            from: nil,
            wordTranscript: words
        )
        XCTAssertGreaterThan(entries.count, 1)
        for entry in entries {
            XCTAssertLessThanOrEqual(entry.relativeDuration, 3.5 + 0.001)
        }
    }

    // MARK: - Subtitle cue manipulation (timeline S1 lane)

    private func makeViewModelWithSingleSegment(
        durationSec: Double = 10,
        speed: Double = 1.0,
        subtitles: [SubtitleEntry] = []
    ) -> (MediaCoreViewModel, UUID) {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))
        var seg = TimelineSegment(
            id: UUID(),
            sourceVideoID: UUID(),
            range: TimeRange(startSeconds: 0, endSeconds: durationSec * speed),
            text: "",
            subtitles: subtitles
        )
        seg.speedRate = speed
        vm.timelineSegments = [seg]
        return (vm, seg.id)
    }

    func test_moveSubtitle_shiftsRelativeStartByComposedDelta() {
        let cueID = UUID()
        let (vm, _) = makeViewModelWithSingleSegment(
            subtitles: [SubtitleEntry(id: cueID, relativeStart: 1.0, relativeDuration: 1.0, text: "x")]
        )
        // Move composed start 1.0 → 3.5. Speed 1.0, so source delta == composed delta.
        vm.moveSubtitle(id: cueID, to: 3.5)
        let cue = vm.timelineSegments[0].subtitles[0]
        XCTAssertEqual(cue.relativeStart, 3.5, accuracy: 0.001)
        XCTAssertEqual(cue.relativeDuration, 1.0, accuracy: 0.001)
    }

    func test_moveSubtitle_atSpeed2x_appliesSourceDeltaTwiceComposed() {
        let cueID = UUID()
        let (vm, _) = makeViewModelWithSingleSegment(
            durationSec: 10, speed: 2.0,
            subtitles: [SubtitleEntry(id: cueID, relativeStart: 0, relativeDuration: 2.0, text: "x")]
        )
        // 10s composed segment at speed 2 = 20s source. Move composed start to 4.0
        // → source 8.0.
        vm.moveSubtitle(id: cueID, to: 4.0)
        XCTAssertEqual(vm.timelineSegments[0].subtitles[0].relativeStart, 8.0, accuracy: 0.001)
    }

    func test_moveSubtitle_clampsToSegmentEnd() {
        let cueID = UUID()
        let (vm, _) = makeViewModelWithSingleSegment(
            durationSec: 10,
            subtitles: [SubtitleEntry(id: cueID, relativeStart: 1.0, relativeDuration: 2.0, text: "x")]
        )
        vm.moveSubtitle(id: cueID, to: 50)
        let cue = vm.timelineSegments[0].subtitles[0]
        // The end (start+duration) must not exceed segment source duration (10).
        XCTAssertLessThanOrEqual(cue.relativeStart + cue.relativeDuration, 10 + 0.001)
    }

    func test_moveSubtitle_doesNotOverlapNeighbor() {
        let cueA = UUID(), cueB = UUID()
        let (vm, _) = makeViewModelWithSingleSegment(
            subtitles: [
                SubtitleEntry(id: cueA, relativeStart: 0, relativeDuration: 1.5, text: "A"),
                SubtitleEntry(id: cueB, relativeStart: 5, relativeDuration: 1.5, text: "B"),
            ]
        )
        // Try to drag A to 4.5 — its end (6.0) would overlap B's start (5). Clamp.
        vm.moveSubtitle(id: cueA, to: 4.5)
        let a = vm.timelineSegments[0].subtitles.first { $0.id == cueA }!
        let b = vm.timelineSegments[0].subtitles.first { $0.id == cueB }!
        XCTAssertLessThanOrEqual(a.relativeStart + a.relativeDuration, b.relativeStart + 0.001)
    }

    func test_resizeSubtitle_trailingEdge_growsDuration() {
        let cueID = UUID()
        let (vm, _) = makeViewModelWithSingleSegment(
            subtitles: [SubtitleEntry(id: cueID, relativeStart: 1.0, relativeDuration: 1.0, text: "x")]
        )
        vm.resizeSubtitle(id: cueID, edge: .trailing, toComposedTime: 5.0)
        let cue = vm.timelineSegments[0].subtitles[0]
        XCTAssertEqual(cue.relativeStart, 1.0, accuracy: 0.001)
        XCTAssertEqual(cue.relativeStart + cue.relativeDuration, 5.0, accuracy: 0.001)
    }

    func test_resizeSubtitle_leadingEdge_shrinksFromLeft() {
        let cueID = UUID()
        let (vm, _) = makeViewModelWithSingleSegment(
            subtitles: [SubtitleEntry(id: cueID, relativeStart: 1.0, relativeDuration: 3.0, text: "x")]
        )
        vm.resizeSubtitle(id: cueID, edge: .leading, toComposedTime: 2.0)
        let cue = vm.timelineSegments[0].subtitles[0]
        XCTAssertEqual(cue.relativeStart, 2.0, accuracy: 0.001)
        XCTAssertEqual(cue.relativeStart + cue.relativeDuration, 4.0, accuracy: 0.001)
    }

    func test_resizeSubtitle_enforcesMinDuration() {
        let cueID = UUID()
        let (vm, _) = makeViewModelWithSingleSegment(
            subtitles: [SubtitleEntry(id: cueID, relativeStart: 1.0, relativeDuration: 2.0, text: "x")]
        )
        // Try to drag trailing edge inside leading edge.
        vm.resizeSubtitle(id: cueID, edge: .trailing, toComposedTime: 0.5)
        let cue = vm.timelineSegments[0].subtitles[0]
        XCTAssertGreaterThanOrEqual(cue.relativeDuration, 0.15)
    }

    func test_addSubtitle_insertsCueAtComposedTime() {
        let (vm, _) = makeViewModelWithSingleSegment()
        let id = vm.addSubtitle(atComposedTime: 3.0, text: "hello")
        XCTAssertNotNil(id)
        XCTAssertEqual(vm.timelineSegments[0].subtitles.count, 1)
        let cue = vm.timelineSegments[0].subtitles[0]
        XCTAssertEqual(cue.relativeStart, 3.0, accuracy: 0.01)
        XCTAssertEqual(cue.text, "hello")
        XCTAssertEqual(vm.selectedSubtitleID, id)
    }

    func test_addSubtitle_clipsDurationToSegmentEnd() {
        let (vm, _) = makeViewModelWithSingleSegment(durationSec: 5)
        // Click near end with 1s default duration; should clip to ~0.5s.
        let id = vm.addSubtitle(atComposedTime: 4.5)
        XCTAssertNotNil(id)
        let cue = vm.timelineSegments[0].subtitles[0]
        XCTAssertLessThanOrEqual(cue.relativeStart + cue.relativeDuration, 5 + 0.001)
    }

    func test_removeSubtitleEntry_removesCueAndClearsSelection() {
        let cueID = UUID()
        let (vm, _) = makeViewModelWithSingleSegment(
            subtitles: [SubtitleEntry(id: cueID, relativeStart: 0, relativeDuration: 1, text: "x")]
        )
        vm.selectSubtitle(id: cueID)
        XCTAssertEqual(vm.selectedSubtitleID, cueID)
        vm.removeSubtitleEntry(id: cueID)
        XCTAssertTrue(vm.timelineSegments[0].subtitles.isEmpty)
        XCTAssertNil(vm.selectedSubtitleID)
    }

    func test_selectSubtitle_clearsSegmentSelection() {
        let cueID = UUID()
        let (vm, segID) = makeViewModelWithSingleSegment(
            subtitles: [SubtitleEntry(id: cueID, relativeStart: 0, relativeDuration: 1, text: "x")]
        )
        vm.handleSegmentClick(index: 0)
        XCTAssertEqual(vm.selectedSegmentID, segID)
        vm.selectSubtitle(id: cueID)
        XCTAssertEqual(vm.selectedSubtitleID, cueID)
        XCTAssertNil(vm.selectedSegmentID)
        XCTAssertTrue(vm.selectedSegmentIDs.isEmpty)
    }

    func test_handleSegmentClick_clearsSubtitleSelection() {
        let cueID = UUID()
        let (vm, _) = makeViewModelWithSingleSegment(
            subtitles: [SubtitleEntry(id: cueID, relativeStart: 0, relativeDuration: 1, text: "x")]
        )
        vm.selectSubtitle(id: cueID)
        XCTAssertEqual(vm.selectedSubtitleID, cueID)
        vm.handleSegmentClick(index: 0)
        XCTAssertNil(vm.selectedSubtitleID)
    }

    // MARK: - Subtitle Tombstones (transcript-driven delete)

    func test_deleteSubtitleCues_createsTombstonesAndShortensTimeline() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let src = UUID()
        let cue1 = UUID()
        let cue2 = UUID()
        let cue3 = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: src,
                range: TimeRange(startSeconds: 0, endSeconds: 9),
                text: "",
                subtitles: [
                    SubtitleEntry(id: cue1, relativeStart: 0.0, relativeDuration: 3.0, text: "hello"),
                    SubtitleEntry(id: cue2, relativeStart: 3.0, relativeDuration: 3.0, text: "middle"),
                    SubtitleEntry(id: cue3, relativeStart: 6.0, relativeDuration: 3.0, text: "world")
                ]
            )
        ]
        vm.rebuildComposedSubtitles()
        XCTAssertEqual(vm.composedSubtitles.count, 3)
        let totalBefore = vm.timelineSegments.map(\.durationSeconds).reduce(0, +)

        // Delete the first and third cues — non-contiguous, exercises
        // the descending-order batching.
        vm.deleteSubtitleCues(ids: [cue1, cue3])

        XCTAssertEqual(vm.subtitleTombstones.count, 2)
        let tombIDs = Set(vm.subtitleTombstones.map(\.id))
        XCTAssertTrue(tombIDs.contains(cue1))
        XCTAssertTrue(tombIDs.contains(cue3))

        let totalAfter = vm.timelineSegments.map(\.durationSeconds).reduce(0, +)
        XCTAssertEqual(totalAfter, totalBefore - 6.0, accuracy: 0.05)

        vm.rebuildComposedSubtitles()
        let remainingCueIDs = Set(vm.composedSubtitles.map(\.id))
        XCTAssertFalse(remainingCueIDs.contains(cue1))
        XCTAssertFalse(remainingCueIDs.contains(cue3))
    }

    /// Regression: after `识别说话人` (diarization) has stamped
    /// `speakerID` on each `SubtitleEntry`, deleting one cue must not
    /// reset the surviving cues' speakerIDs to nil. The bug was that
    /// `subtitleEntries(for:sourceVideoID:)` rebuilt entries from the
    /// copilot snapshot (which never carries speakerID), so every
    /// AIAction routing through `transcriptLookup` (delete / split /
    /// trim / setSpeed) silently dropped diarization metadata and
    /// the transcript collapsed to a single default speaker.
    func test_deleteSubtitleCue_preservesSpeakerIDsOnSurvivingCues() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let src = UUID()
        let cue1 = UUID()
        let cue2 = UUID()
        let cue3 = UUID()
        // Copilot snapshot mirrors the live cues' text + timings so
        // `buildSubtitleEntries` regenerates the same shape on the
        // surviving slices, letting our text-equality check accept
        // translations / runs preservation later if added.
        var record = MediaAssetRecord(
            id: src,
            sourcePath: "/tmp/\(src.uuidString).mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 9, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: "p.mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        record.copilot = AICopilotSnapshot(
            semanticTags: [],
            issues: [],
            suggestions: [],
            markers: [],
            transcript: [
                TranscriptSegment(startSeconds: 0.0, endSeconds: 3.0, text: "hello"),
                TranscriptSegment(startSeconds: 3.0, endSeconds: 6.0, text: "middle"),
                TranscriptSegment(startSeconds: 6.0, endSeconds: 9.0, text: "world"),
            ]
        )
        vm.records = [record]
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: src,
                range: TimeRange(startSeconds: 0, endSeconds: 9),
                text: "",
                subtitles: [
                    SubtitleEntry(id: cue1, relativeStart: 0.0, relativeDuration: 3.0, text: "hello", speakerID: 0),
                    SubtitleEntry(id: cue2, relativeStart: 3.0, relativeDuration: 3.0, text: "middle", speakerID: 1),
                    SubtitleEntry(id: cue3, relativeStart: 6.0, relativeDuration: 3.0, text: "world", speakerID: 0),
                ]
            )
        ]
        vm.rebuildComposedSubtitles()

        // Delete the middle cue (the one whose speaker should NOT
        // bleed into the survivors).
        vm.deleteSubtitleCues(ids: [cue2])

        vm.rebuildComposedSubtitles()
        let cuesByText = Dictionary(uniqueKeysWithValues: vm.composedSubtitles.map { ($0.text, $0) })
        XCTAssertEqual(cuesByText["hello"]?.speakerID, 0,
                       "Surviving 'hello' cue must keep its diarized speakerID after delete")
        XCTAssertEqual(cuesByText["world"]?.speakerID, 0,
                       "Surviving 'world' cue must keep its diarized speakerID after delete")
        XCTAssertNil(cuesByText["middle"], "deleted cue should be gone")
    }

    /// Regression: deleting a cue must not erase the surviving cues'
    /// translations either. Same root cause as the speakerID bug.
    func test_deleteSubtitleCue_preservesTranslationsOnSurvivingCues() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let src = UUID()
        let cue1 = UUID()
        let cue2 = UUID()
        let cue3 = UUID()
        var record = MediaAssetRecord(
            id: src,
            sourcePath: "/tmp/\(src.uuidString).mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 9, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: "p.mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        record.copilot = AICopilotSnapshot(
            semanticTags: [],
            issues: [],
            suggestions: [],
            markers: [],
            transcript: [
                TranscriptSegment(startSeconds: 0.0, endSeconds: 3.0, text: "hello"),
                TranscriptSegment(startSeconds: 3.0, endSeconds: 6.0, text: "middle"),
                TranscriptSegment(startSeconds: 6.0, endSeconds: 9.0, text: "world"),
            ]
        )
        vm.records = [record]
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: src,
                range: TimeRange(startSeconds: 0, endSeconds: 9),
                text: "",
                subtitles: [
                    SubtitleEntry(
                        id: cue1, relativeStart: 0.0, relativeDuration: 3.0, text: "hello",
                        translations: ["zh-Hans": "你好"]
                    ),
                    SubtitleEntry(id: cue2, relativeStart: 3.0, relativeDuration: 3.0, text: "middle"),
                    SubtitleEntry(
                        id: cue3, relativeStart: 6.0, relativeDuration: 3.0, text: "world",
                        translations: ["zh-Hans": "世界"]
                    ),
                ]
            )
        ]
        vm.rebuildComposedSubtitles()

        vm.deleteSubtitleCues(ids: [cue2])

        vm.rebuildComposedSubtitles()
        let cuesByText = Dictionary(uniqueKeysWithValues: vm.composedSubtitles.map { ($0.text, $0) })
        XCTAssertEqual(cuesByText["hello"]?.translations["zh-Hans"], "你好",
                       "Surviving 'hello' cue must keep its translations after delete")
        XCTAssertEqual(cuesByText["world"]?.translations["zh-Hans"], "世界",
                       "Surviving 'world' cue must keep its translations after delete")
    }

    /// Regression: closing a project mid-analysis (or after a clean
    /// exit while a tool was running) used to leave `.working`
    /// bubbles persisted on disk. Reopening the project re-spun
    /// them as phantom spinners next to work that actually finished
    /// long ago — particularly noticeable after `识别说话人`
    /// because `transcribeForDiarization` posts a persisted
    /// `.working` bubble that isn't finalized by any of the
    /// `appendAnalysisAssistantLine` resolution paths. Sanity-check
    /// that `loadChatHistory` demotes any persisted `.working`
    /// bubbles to `.success` on load.
    func test_loadChatHistory_demotesStaleWorkingBubbles() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cutti-load-chat-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot.appending(path: "media"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Pre-seed a persisted chat with one stale `.working` bubble
        // and one already-finalized `.success` bubble.
        let stuckBubble = EditorChatMessage(
            role: .assistant,
            content: "Transcribing for speaker detection…",
            iconSystemName: "waveform",
            iconTone: .working
        )
        let okBubble = EditorChatMessage(
            role: .assistant,
            content: "🗣 Detected 2 speakers.",
            iconSystemName: "checkmark.circle.fill",
            iconTone: .success
        )
        let store = ChatStore(projectRoot: tempRoot)
        try await store.append(stuckBubble)
        try await store.append(okBubble)

        let vm = await MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            projectRoot: tempRoot
        )
        await vm.loadChatHistory()

        let messages = await vm.chatMessages
        XCTAssertEqual(messages.count, 2)
        let stuck = messages.first { $0.id == stuckBubble.id }
        XCTAssertEqual(stuck?.iconTone, .success,
                       "Persisted .working bubble must be demoted to .success on load.")
        XCTAssertEqual(stuck?.iconSystemName, "checkmark.circle.fill",
                       "Demoted bubble should switch to the success checkmark icon.")
        let ok = messages.first { $0.id == okBubble.id }
        XCTAssertEqual(ok?.iconTone, .success,
                       "Already-finalized .success bubble must be left alone.")

        // The demoted state must also be persisted, so the *next*
        // reload sees the same shape (no lingering working bubbles).
        let vm2 = await MediaCoreViewModel(
            playbackCore: SpyPlaybackCore(),
            projectRoot: tempRoot
        )
        await vm2.loadChatHistory()
        let reloaded = await vm2.chatMessages
        XCTAssertEqual(reloaded.first { $0.id == stuckBubble.id }?.iconTone, .success,
                       "Demotion should round-trip through disk.")
    }

    func test_rebuildComposedSubtitles_propagatesWordTimings_speedRate1() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let cueID = UUID()
        let timings: [WordTiming] = [
            WordTiming(text: "你", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: "好", startSeconds: 0.4, endSeconds: 1.0)
        ]
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 1.5),
                text: "你好",
                subtitles: [
                    SubtitleEntry(
                        id: cueID,
                        relativeStart: 0.0,
                        relativeDuration: 1.0,
                        text: "你好",
                        wordTimings: timings
                    )
                ]
            )
        ]

        vm.rebuildComposedSubtitles()

        XCTAssertEqual(vm.composedSubtitles.count, 1)
        let cue = vm.composedSubtitles[0]
        XCTAssertEqual(cue.id, cueID)
        XCTAssertNotNil(cue.wordTimings)
        XCTAssertEqual(cue.wordTimings?.count, 2)
        XCTAssertEqual(cue.wordTimings?[0].text, "你")
        XCTAssertEqual(cue.wordTimings?[0].startSeconds ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(cue.wordTimings?[0].endSeconds ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(cue.wordTimings?[1].startSeconds ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(cue.wordTimings?[1].endSeconds ?? -1, 1.0, accuracy: 0.001)
    }

    func test_rebuildComposedSubtitles_scalesWordTimings_by_2x_speedRate() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let cueID = UUID()
        // Pre-speed entry: relativeStart=0, relativeDuration=1.0, words at 0..0.4 and 0.4..1.0.
        // At 2x speed, composed cue runs 0..0.5 and word timings should
        // collapse to 0..0.2 and 0.2..0.5 (entry-relative composed seconds).
        let timings: [WordTiming] = [
            WordTiming(text: "A", startSeconds: 0.0, endSeconds: 0.4),
            WordTiming(text: "B", startSeconds: 0.4, endSeconds: 1.0)
        ]
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 2),
                text: "AB",
                subtitles: [
                    SubtitleEntry(
                        id: cueID,
                        relativeStart: 0.0,
                        relativeDuration: 1.0,
                        text: "AB",
                        wordTimings: timings
                    )
                ],
                speedRate: 2.0
            )
        ]

        vm.rebuildComposedSubtitles()

        XCTAssertEqual(vm.composedSubtitles.count, 1)
        let cue = vm.composedSubtitles[0]
        XCTAssertEqual(cue.endSeconds - cue.startSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(cue.wordTimings?.count, 2)
        XCTAssertEqual(cue.wordTimings?[0].startSeconds ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(cue.wordTimings?[0].endSeconds ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(cue.wordTimings?[1].startSeconds ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(cue.wordTimings?[1].endSeconds ?? -1, 0.5, accuracy: 0.001)
    }

    func test_rebuildComposedSubtitles_nilWordTimings_passesNilThrough() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let cueID = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: UUID(),
                range: TimeRange(startSeconds: 0, endSeconds: 2),
                text: "hello",
                subtitles: [
                    SubtitleEntry(id: cueID, relativeStart: 0, relativeDuration: 1, text: "hello")
                ]
            )
        ]

        vm.rebuildComposedSubtitles()

        XCTAssertEqual(vm.composedSubtitles.count, 1)
        XCTAssertNil(vm.composedSubtitles[0].wordTimings)
    }

    func test_restoreSubtitleTombstone_reAddsSegmentAndClearsTombstone() {
        let spy = SpyPlaybackCore()
        let vm = MediaCoreViewModel(playbackCore: spy, projectRoot: URL(fileURLWithPath: "/project"))

        let src = UUID()
        let cueID = UUID()
        vm.timelineSegments = [
            TimelineSegment(
                id: UUID(),
                sourceVideoID: src,
                range: TimeRange(startSeconds: 0, endSeconds: 6),
                text: "",
                subtitles: [
                    SubtitleEntry(id: UUID(), relativeStart: 0.0, relativeDuration: 2.0, text: "keep"),
                    SubtitleEntry(id: cueID, relativeStart: 2.0, relativeDuration: 2.0, text: "bye"),
                    SubtitleEntry(id: UUID(), relativeStart: 4.0, relativeDuration: 2.0, text: "rest")
                ]
            )
        ]
        vm.rebuildComposedSubtitles()

        vm.deleteSubtitleCue(id: cueID)
        XCTAssertEqual(vm.subtitleTombstones.count, 1)
        let segCountAfterDelete = vm.timelineSegments.count

        vm.restoreSubtitleTombstone(id: cueID)
        XCTAssertEqual(vm.subtitleTombstones.count, 0)
        XCTAssertEqual(vm.timelineSegments.count, segCountAfterDelete + 1)

        // Restored segment should splice back between its neighbours
        // (source-time ordering), not dump at the end. With a middle
        // cue deleted from a single source, the restored segment's
        // index should be 1 (between the two surviving halves), and
        // source ranges should come out in ascending order.
        let primarySourceStarts = vm.timelineSegments
            .filter { $0.sourceVideoID == src }
            .map(\.range.startSeconds)
        XCTAssertEqual(primarySourceStarts, primarySourceStarts.sorted(),
                       "Restored segment should sit in source-time order, not appended at end")
        XCTAssertTrue(vm.timelineSegments.contains(where: { $0.subtitles.first?.text == "bye" }))
    }

    func test_editorSessionState_decode_withoutTombstones_defaultsEmpty() throws {
        // Old session.json (pre-tombstone feature) — must decode fine.
        let legacyJSON = """
        {
          "subtitleStyle": \(String(data: try JSONEncoder().encode(SubtitleStyle.default), encoding: .utf8)!),
          "showSubtitles": true
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorSessionState.self, from: legacyJSON)
        XCTAssertTrue(decoded.subtitleTombstones.isEmpty)
        XCTAssertEqual(decoded.showSubtitles, true)
    }

    // MARK: - rebuildTimelineSegments idempotency (M² explosion regression)

    private func makeAnalyzedRecordForRebuild(
        id: UUID = UUID(),
        durationSeconds: Double = 100.0,
        keptRanges: [TimeRange]
    ) -> MediaAssetRecord {
        var record = MediaAssetRecord(
            id: id,
            sourcePath: "/tmp/\(id.uuidString).mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: durationSeconds, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: "p.mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        record.copilot = AICopilotSnapshot(
            semanticTags: [],
            issues: [],
            suggestions: [],
            markers: [],
            keptRanges: keptRanges
        )
        return record
    }

    func test_rebuildTimeline_expandsFullSourcePlaceholder() {
        // The "first cut just finished" path: timeline had a single
        // full-source placeholder; rebuild should explode it into one
        // segment per kept range.
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let recordID = UUID()
        let kept = [
            TimeRange(startSeconds: 5, endSeconds: 15),
            TimeRange(startSeconds: 30, endSeconds: 45),
            TimeRange(startSeconds: 60, endSeconds: 80),
        ]
        vm.records = [makeAnalyzedRecordForRebuild(id: recordID, durationSeconds: 100, keptRanges: kept)]
        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: recordID, range: TimeRange(startSeconds: 0, endSeconds: 100), text: "", subtitles: []),
        ]

        // Trigger rebuild via select — same path that the AI completion
        // hits when it re-selects the record.
        vm.select(recordID: recordID)

        XCTAssertEqual(vm.timelineSegments.count, kept.count,
                       "Placeholder should expand to one segment per kept range")
    }

    func test_rebuildTimeline_isIdempotent_doesNotMultiplyExpandedSegments() {
        // Regression: pre-fix, walking already-expanded sub-range
        // segments would re-expand each into N keptRanges → N² growth.
        // After fix, every call past the first must be a no-op.
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let recordID = UUID()
        let kept = (0..<10).map { i in
            TimeRange(startSeconds: Double(i) * 9.0, endSeconds: Double(i) * 9.0 + 5)
        }
        vm.records = [makeAnalyzedRecordForRebuild(id: recordID, durationSeconds: 100, keptRanges: kept)]
        vm.timelineSegments = [
            TimelineSegment(id: UUID(), sourceVideoID: recordID, range: TimeRange(startSeconds: 0, endSeconds: 100), text: "", subtitles: []),
        ]

        vm.select(recordID: recordID)
        let afterFirst = vm.timelineSegments.count
        XCTAssertEqual(afterFirst, kept.count)

        // Second select would have produced afterFirst² before the fix.
        vm.select(recordID: recordID)
        XCTAssertEqual(vm.timelineSegments.count, afterFirst,
                       "rebuildTimelineSegments must be idempotent — no growth on second call")

        // And a few more for good measure (the original bug was M³,
        // M⁴, … on every subsequent select).
        for _ in 0..<5 { vm.select(recordID: recordID) }
        XCTAssertEqual(vm.timelineSegments.count, afterFirst,
                       "Repeated rebuilds must not grow the timeline")
    }

    func test_rebuildTimeline_keepsManuallyTrimmedSlotVerbatim() {
        // A user-trimmed slot must NOT be re-expanded by rebuild — its
        // bounds are user intent, not a placeholder.
        let vm = MediaCoreViewModel(playbackCore: SpyPlaybackCore())
        let recordID = UUID()
        let kept = [TimeRange(startSeconds: 5, endSeconds: 15)]
        vm.records = [makeAnalyzedRecordForRebuild(id: recordID, durationSeconds: 100, keptRanges: kept)]
        let trimmedSlotID = UUID()
        vm.timelineSegments = [
            TimelineSegment(id: trimmedSlotID, sourceVideoID: recordID, range: TimeRange(startSeconds: 20, endSeconds: 40), text: "manual", subtitles: []),
        ]

        vm.select(recordID: recordID)

        XCTAssertEqual(vm.timelineSegments.count, 1)
        XCTAssertEqual(vm.timelineSegments.first?.range.startSeconds, 20)
        XCTAssertEqual(vm.timelineSegments.first?.range.endSeconds, 40)
    }
}
