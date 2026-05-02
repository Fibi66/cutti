import XCTest
import CuttiKit
@testable import CuttiMac

final class ProjectStoreTests: XCTestCase {
    func test_createProject_createsDerivedDirectories_andRoundTripsManifest() throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)

        try store.bootstrapProject()

        // Issue 2: Verify all required directories exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.url.appending(path: "media/proxies").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.url.appending(path: "media/thumbnails").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.url.appending(path: "media/waveforms").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.url.appending(path: "logs").path))

        // Issue 3: Verify bootstrapProject() created an empty manifest
        let initialManifest = try store.loadManifest()
        XCTAssertEqual(initialManifest.media.count, 0)

        // Issue 4: Use concrete non-trivial date for round-trip verification
        let concreteDate = Date(timeIntervalSince1970: 1704067200) // 2024-01-01 00:00:00 UTC
        var manifest = MediaManifest()
        manifest.media = [
            MediaAssetRecord(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                sourcePath: "/tmp/source.mp4",
                fingerprint: .init(fileSize: 12, modifiedAt: concreteDate, sha256Prefix: "abcd1234"),
                status: .queued,
                analysis: nil,
                derived: .init(proxyRelativePath: nil, thumbnailsReady: false, waveformsReady: false),
                errorMessage: nil,
                usedFallbackTranscoder: false
            )
        ]

        // Attach a copilot snapshot before saving
        let copilotSnapshot = AICopilotSnapshot(
            semanticTags: ["Hook", "Dialogue"],
            summary: "Opening beat lands quickly and the speaker is centered.",
            transcriptPreview: "Welcome back to Cutti.",
            suggestedInSeconds: 0.5,
            suggestedOutSeconds: 8.0,
            issues: [],
            suggestions: [],
            markers: [
                AICopilotMarker(kind: .scene, seconds: 0.0, label: "Hook starts")
            ]
        )
        manifest.media[0].copilot = copilotSnapshot

        try store.saveManifest(manifest)
        let reloaded = try store.loadManifest()

        XCTAssertEqual(reloaded.media.count, 1)
        XCTAssertEqual(reloaded.media[0].status, .queued)
        XCTAssertEqual(reloaded.media[0].fingerprint.modifiedAt, concreteDate)

        // Copilot snapshot round-trip assertions
        let reloadedCopilot = try XCTUnwrap(reloaded.media[0].copilot)
        XCTAssertEqual(reloadedCopilot, copilotSnapshot)
    }

    func test_proxyURL_usesAppleSiliconEditingProxyProfile() throws {
        let temp = try TemporaryDirectory()
        let store = ProjectStore(projectRoot: temp.url)
        let mediaID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let proxyURL = store.proxyURL(for: mediaID)

        XCTAssertEqual(proxyURL.lastPathComponent, "\(mediaID.uuidString).mov")
        XCTAssertTrue(
            proxyURL.path.contains("media/proxies"),
            "Proxy URL path should contain 'media/proxies' but was: \(proxyURL.path)"
        )
        XCTAssertEqual(
            proxyURL,
            temp.url.appending(path: "media/proxies/\(mediaID.uuidString).mov")
        )
    }
}
