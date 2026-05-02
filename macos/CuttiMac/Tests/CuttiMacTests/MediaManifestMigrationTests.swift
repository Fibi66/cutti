import XCTest
import CuttiKit
@testable import CuttiMac

/// Locks in the legacy-manifest back-compat story for `MediaAssetRecord`:
/// pre-image-feature JSON has no `kind` field and must decode with
/// `kind = .video`. A synthesized Decodable would throw `keyNotFound`,
/// so a regression here means someone removed the custom `init(from:)`.
final class MediaManifestMigrationTests: XCTestCase {
    func test_legacyRecordWithoutKindField_decodesAsVideo() throws {
        // JSON captured from a manifest file produced before the
        // MediaKind field existed. No `kind` key.
        let json = """
        {
            "id": "AAAA1111-0000-0000-0000-000000000001",
            "sourcePath": "/tmp/clip.mov",
            "fingerprint": {
                "fileSize": 12345,
                "modifiedAt": 731001600,
                "sha256Prefix": "deadbeef"
            },
            "status": "ready",
            "derived": {
                "thumbnailsReady": true,
                "waveformsReady": true
            },
            "usedFallbackTranscoder": false
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(MediaAssetRecord.self, from: json)
        XCTAssertEqual(record.kind, .video)
        XCTAssertEqual(record.sourcePath, "/tmp/clip.mov")
    }

    func test_imageRecord_roundTripsKindField() throws {
        let record = MediaAssetRecord(
            id: UUID(),
            sourcePath: "/tmp/pic.png",
            fingerprint: SourceFingerprint(fileSize: 100, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), sha256Prefix: "abc"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 0, width: 1920, height: 1080, nominalFPS: 0, hasAudio: false),
            derived: .init(proxyRelativePath: nil, thumbnailsReady: true, waveformsReady: true),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            kind: .image
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(MediaAssetRecord.self, from: data)

        XCTAssertEqual(decoded.kind, .image)
        XCTAssertEqual(decoded.sourcePath, "/tmp/pic.png")
    }

    func test_sourceUpperBoundSeconds_isNilForImage() {
        let image = MediaAssetRecord(
            id: UUID(),
            sourcePath: "/tmp/pic.png",
            fingerprint: SourceFingerprint(fileSize: 1, modifiedAt: .distantPast, sha256Prefix: "a"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 0, width: 100, height: 100, nominalFPS: 0, hasAudio: false),
            derived: .init(proxyRelativePath: nil, thumbnailsReady: true, waveformsReady: true),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            kind: .image
        )
        XCTAssertNil(image.sourceUpperBoundSeconds)
        XCTAssertFalse(image.isAnalyzable)

        let video = MediaAssetRecord(
            id: UUID(),
            sourcePath: "/tmp/v.mov",
            fingerprint: SourceFingerprint(fileSize: 1, modifiedAt: .distantPast, sha256Prefix: "b"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 42, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: .init(proxyRelativePath: "proxy.mov", thumbnailsReady: true, waveformsReady: true),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        XCTAssertEqual(video.sourceUpperBoundSeconds, 42)
        XCTAssertTrue(video.isAnalyzable)
    }
}
