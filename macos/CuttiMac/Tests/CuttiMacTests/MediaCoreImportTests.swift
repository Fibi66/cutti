import Foundation
import XCTest
import CryptoKit
import CuttiKit
@testable import CuttiMac

final class MediaCoreImportTests: XCTestCase {
    func test_importLocalVideo_marksRecordReady_whenPrimaryTranscoderSucceeds() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        let sourceURL = temp.url.appending(path: "source.mp4")
        try Data("stub".utf8).write(to: sourceURL)

        let analyzer = StubAnalyzer(summary: .init(
            durationSeconds: 1,
            width: 640,
            height: 360,
            nominalFPS: 30,
            hasAudio: true
        ))
        let primary = StubTranscoder(result: .success)
        let fallback = StubTranscoder(result: .success)

        let core = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: primary, fallbackTranscoder: fallback)
        let mediaId = try await core.importLocalVideo(url: sourceURL)
        let manifest = try store.loadManifest()
        let record = try XCTUnwrap(manifest.media.first { $0.id == mediaId })

        XCTAssertEqual(record.status, .ready)
        XCTAssertEqual(record.derived.proxyRelativePath, "media/proxies/\(mediaId.uuidString).mov")
        XCTAssertFalse(record.usedFallbackTranscoder)
    }

    func test_importLocalVideo_usesFallbackOnlyForFallbackEligibleFailures() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        let sourceURL = temp.url.appending(path: "source.mp4")
        try Data("stub".utf8).write(to: sourceURL)

        let analyzer = StubAnalyzer(summary: .init(
            durationSeconds: 1,
            width: 640,
            height: 360,
            nominalFPS: 30,
            hasAudio: false
        ))
        let primary = StubTranscoder(result: .fallbackEligibleFailure("unsupported export preset"))
        let fallback = StubTranscoder(result: .success)

        let core = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: primary, fallbackTranscoder: fallback)
        let mediaId = try await core.importLocalVideo(url: sourceURL)
        let manifest = try store.loadManifest()
        let record = try XCTUnwrap(manifest.media.first { $0.id == mediaId })

        XCTAssertEqual(record.status, .ready)
        XCTAssertTrue(record.usedFallbackTranscoder)
    }

    func test_importLocalVideo_marksFailed_whenPrimaryFailsWithNonFallbackEligibleError() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        let sourceURL = temp.url.appending(path: "source.mp4")
        try Data("stub".utf8).write(to: sourceURL)

        let analyzer = StubAnalyzer(summary: .init(
            durationSeconds: 1,
            width: 640,
            height: 360,
            nominalFPS: 30,
            hasAudio: true
        ))
        let primary = StubTranscoder(result: .failure("corrupt file"))
        let fallback = StubTranscoder(result: .success)

        let core = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: primary, fallbackTranscoder: fallback)
        let mediaId = try await core.importLocalVideo(url: sourceURL)
        let manifest = try store.loadManifest()
        let record = try XCTUnwrap(manifest.media.first { $0.id == mediaId })

        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.errorMessage, "corrupt file")
        XCTAssertFalse(record.usedFallbackTranscoder)
    }

    func test_importLocalVideo_marksFailed_whenFallbackEligibleFailureButNoFallbackConfigured() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        let sourceURL = temp.url.appending(path: "source.mp4")
        try Data("stub".utf8).write(to: sourceURL)

        let analyzer = StubAnalyzer(summary: .init(
            durationSeconds: 1,
            width: 640,
            height: 360,
            nominalFPS: 30,
            hasAudio: true
        ))
        let primary = StubTranscoder(result: .fallbackEligibleFailure("unsupported preset"))

        let core = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: primary, fallbackTranscoder: nil)
        let mediaId = try await core.importLocalVideo(url: sourceURL)
        let manifest = try store.loadManifest()
        let record = try XCTUnwrap(manifest.media.first { $0.id == mediaId })

        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.errorMessage, L("Primary transcoder failed and no fallback is configured"))
        XCTAssertFalse(record.usedFallbackTranscoder)
    }

    func test_relinkOriginal_updatesSourcePath_setsStatusQueued_clearsError() throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        
        // Create a record with failed status and error message
        let mediaId = UUID()
        var manifest = try store.loadManifest()
        manifest.media.append(MediaAssetRecord(
            id: mediaId,
            sourcePath: "/old/path.mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc123"),
            status: .failed,
            analysis: nil,
            derived: .init(proxyRelativePath: nil, thumbnailsReady: false, waveformsReady: false),
            errorMessage: "original error",
            usedFallbackTranscoder: false
        ))
        try store.saveManifest(manifest)

        let analyzer = StubAnalyzer(summary: .init(
            durationSeconds: 1,
            width: 640,
            height: 360,
            nominalFPS: 30,
            hasAudio: true
        ))
        let primary = StubTranscoder(result: .success)
        let core = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: primary, fallbackTranscoder: nil)

        // Create the new source file before relinking
        let newURL = temp.url.appending(path: "new_path.mp4")
        try Data("new video content".utf8).write(to: newURL)
        
        try core.relinkOriginal(mediaId: mediaId, newURL: newURL)

        let updatedManifest = try store.loadManifest()
        let record = try XCTUnwrap(updatedManifest.media.first { $0.id == mediaId })

        XCTAssertEqual(record.sourcePath, newURL.path)
        XCTAssertEqual(record.status, .queued)
        XCTAssertNil(record.errorMessage)
        
        // Should have updated fingerprint to new file
        XCTAssertNotEqual(record.fingerprint.sha256Prefix, "abc123")
        XCTAssertNotEqual(record.fingerprint.fileSize, 1000)
    }

    func test_importLocalVideo_marksFailed_whenPrimaryFallbackEligibleFailureAndFallbackFails() async throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        let sourceURL = temp.url.appending(path: "source.mp4")
        try Data("stub".utf8).write(to: sourceURL)

        let analyzer = StubAnalyzer(summary: .init(
            durationSeconds: 1,
            width: 640,
            height: 360,
            nominalFPS: 30,
            hasAudio: true
        ))
        let primary = StubTranscoder(result: .fallbackEligibleFailure("primary issue"))
        let fallback = StubTranscoder(result: .failure("fallback critical error"))

        let core = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: primary, fallbackTranscoder: fallback)
        let mediaId = try await core.importLocalVideo(url: sourceURL)
        let manifest = try store.loadManifest()
        let record = try XCTUnwrap(manifest.media.first { $0.id == mediaId })

        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.errorMessage, "fallback critical error")
        XCTAssertFalse(record.usedFallbackTranscoder)
    }

    func test_relinkOriginal_throwsRecordNotFound_whenMediaIdDoesNotExist() throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()

        let analyzer = StubAnalyzer(summary: .init(
            durationSeconds: 1,
            width: 640,
            height: 360,
            nominalFPS: 30,
            hasAudio: true
        ))
        let primary = StubTranscoder(result: .success)
        let core = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: primary, fallbackTranscoder: nil)

        let nonExistentId = UUID()
        let newURL = temp.url.appending(path: "new_path.mp4")
        
        XCTAssertThrowsError(try core.relinkOriginal(mediaId: nonExistentId, newURL: newURL)) { error in
            guard case MediaCoreError.recordNotFound(let id) = error else {
                XCTFail("Expected MediaCoreError.recordNotFound but got \(error)")
                return
            }
            XCTAssertEqual(id, nonExistentId)
        }
    }
    
    // MARK: - Task 8: Validate Sources
    
    func test_validateSources_marksMissing_whenSourceFileDoesNotExist() throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        
        // Create a record pointing to a non-existent file
        let mediaId = UUID()
        var manifest = try store.loadManifest()
        manifest.media.append(MediaAssetRecord(
            id: mediaId,
            sourcePath: "/nonexistent/file.mp4",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc123"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 10, width: 640, height: 360, nominalFPS: 30, hasAudio: true),
            derived: .init(proxyRelativePath: "media/proxies/\(mediaId.uuidString).mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        ))
        try store.saveManifest(manifest)
        
        let analyzer = StubAnalyzer(summary: .init(durationSeconds: 1, width: 640, height: 360, nominalFPS: 30, hasAudio: true))
        let primary = StubTranscoder(result: .success)
        let core = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: primary, fallbackTranscoder: nil)
        
        try core.validateSources()
        
        let updatedManifest = try store.loadManifest()
        let record = try XCTUnwrap(updatedManifest.media.first { $0.id == mediaId })
        
        XCTAssertEqual(record.status, .missing)
        XCTAssertEqual(record.errorMessage, L("Original file is missing. Please relink it."))
    }
    
    func test_validateSources_updatesFingerprint_whenSourceChanged() throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        
        // Create an actual source file
        let sourceURL = temp.url.appending(path: "source.mp4")
        try Data("initial content".utf8).write(to: sourceURL)
        
        // Create a record with an old fingerprint
        let mediaId = UUID()
        var manifest = try store.loadManifest()
        manifest.media.append(MediaAssetRecord(
            id: mediaId,
            sourcePath: sourceURL.path,
            fingerprint: SourceFingerprint(fileSize: 999, modifiedAt: Date.distantPast, sha256Prefix: "oldsha"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 10, width: 640, height: 360, nominalFPS: 30, hasAudio: true),
            derived: .init(proxyRelativePath: "media/proxies/\(mediaId.uuidString).mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        ))
        try store.saveManifest(manifest)
        
        let analyzer = StubAnalyzer(summary: .init(durationSeconds: 1, width: 640, height: 360, nominalFPS: 30, hasAudio: true))
        let primary = StubTranscoder(result: .success)
        let core = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: primary, fallbackTranscoder: nil)
        
        try core.validateSources()
        
        let updatedManifest = try store.loadManifest()
        let record = try XCTUnwrap(updatedManifest.media.first { $0.id == mediaId })
        
        // Should update fingerprint to current values
        XCTAssertNotEqual(record.fingerprint.sha256Prefix, "oldsha")
        XCTAssertNotEqual(record.fingerprint.fileSize, 999)
        
        // Should mark as queued for rebuild
        XCTAssertEqual(record.status, .queued)
        XCTAssertEqual(record.errorMessage, L("Source changed on disk. Rebuild the proxy."))
    }
    
    func test_validateSources_leavesUnchanged_whenFingerprintMatches() throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        try store.bootstrapProject()
        
        // Create an actual source file
        let sourceURL = temp.url.appending(path: "source.mp4")
        let content = Data("stable content".utf8)
        try content.write(to: sourceURL)
        
        // Small delay to ensure file system timestamps stabilize
        Thread.sleep(forTimeInterval: 0.1)
        
        // Get the real fingerprint for this file
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = Int64(values.fileSize ?? 0)
        let modifiedAt = values.contentModificationDate ?? .distantPast
        
        // Compute SHA256 prefix
        let fileHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? fileHandle.close() }
        let chunkSize = 1024 * 1024
        let chunk = try fileHandle.read(upToCount: chunkSize) ?? Data()
        let hash = CryptoKit.SHA256.hash(data: chunk)
        let sha256Prefix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        
        // Create a record with matching fingerprint
        let mediaId = UUID()
        var manifest = try store.loadManifest()
        manifest.media.append(MediaAssetRecord(
            id: mediaId,
            sourcePath: sourceURL.path,
            fingerprint: SourceFingerprint(fileSize: fileSize, modifiedAt: modifiedAt, sha256Prefix: sha256Prefix),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 10, width: 640, height: 360, nominalFPS: 30, hasAudio: true),
            derived: .init(proxyRelativePath: "media/proxies/\(mediaId.uuidString).mov", thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        ))
        try store.saveManifest(manifest)
        
        let analyzer = StubAnalyzer(summary: .init(durationSeconds: 1, width: 640, height: 360, nominalFPS: 30, hasAudio: true))
        let primary = StubTranscoder(result: .success)
        let core = MediaCore(store: store, analyzer: analyzer, primaryTranscoder: primary, fallbackTranscoder: nil)
        
        try core.validateSources()
        
        let updatedManifest = try store.loadManifest()
        let record = try XCTUnwrap(updatedManifest.media.first { $0.id == mediaId })
        
        // Should remain unchanged
        XCTAssertEqual(record.status, .ready)
        XCTAssertNil(record.errorMessage)
        XCTAssertEqual(record.fingerprint.fileSize, fileSize)
        XCTAssertEqual(record.fingerprint.sha256Prefix, sha256Prefix)
    }
}

private struct StubAnalyzer: AssetAnalyzing {
    let summary: AnalysisSummary
    func analyze(url: URL) async throws -> AnalysisSummary { summary }
}

private struct StubTranscoder: ProxyTranscoding {
    let result: TranscodeResult
    func transcode(sourceURL: URL, destinationURL: URL) async -> TranscodeResult { result }
}
