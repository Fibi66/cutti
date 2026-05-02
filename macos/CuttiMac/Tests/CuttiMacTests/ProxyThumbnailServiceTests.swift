import AppKit
import CoreMedia
import XCTest
import CuttiKit
@testable import CuttiMac

// `NSImage` is not `Sendable` in Swift's type system, but this stub is
// immutable and only used on the main actor in tests, so @unchecked Sendable is safe.
private struct StubProxyThumbnailGenerator: ProxyThumbnailGenerating, @unchecked Sendable {
    let image: NSImage?
    func generateImage(proxyURL: URL, at time: CMTime) async -> NSImage? { image }
}

// MARK: - Call-counting generator

/// Thread-safe call counter used to verify the thumbnail cache prevents
/// redundant generator invocations.
private actor GeneratorCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct CountingProxyThumbnailGenerator: ProxyThumbnailGenerating, Sendable {
    let counter: GeneratorCallCounter
    let image: NSImage?

    func generateImage(proxyURL: URL, at time: CMTime) async -> NSImage? {
        await counter.increment()
        return image
    }
}

// MARK: - Scripted generator

/// Returns a pre-defined sequence of responses, one per call.
/// Used to test error-recovery behaviour (e.g., nil → image on retry).
private actor ScriptedProxyThumbnailGenerator: ProxyThumbnailGenerating {
    private let responses: [NSImage?]
    private(set) var callCount = 0

    init(responses: [NSImage?]) {
        self.responses = responses
    }

    func generateImage(proxyURL: URL, at time: CMTime) async -> NSImage? {
        defer { callCount += 1 }
        guard callCount < responses.count else { return nil }
        return responses[callCount]
    }
}

final class ProxyThumbnailServiceTests: XCTestCase {
    private func makeRecord(
        status: MediaStatus = .ready,
        proxyRelativePath: String? = "media/proxies/sample.mov"
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sourcePath: "/tmp/source.mov",
            fingerprint: SourceFingerprint(fileSize: 10, modifiedAt: .distantPast, sha256Prefix: "abc"),
            status: status,
            analysis: AnalysisSummary(durationSeconds: 4, width: 1280, height: 720, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: proxyRelativePath, thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
    }

    @MainActor
    func test_requestKey_changesWhenProxyInputsChange() async {
        let ready = makeRecord()
        let missing = makeRecord(status: .missing, proxyRelativePath: nil)

        let readyKey = ProxyThumbnailService.requestKey(for: ready, projectRoot: URL(fileURLWithPath: "/project"))
        let missingKey = ProxyThumbnailService.requestKey(for: missing, projectRoot: URL(fileURLWithPath: "/project"))

        XCTAssertNotEqual(readyKey, missingKey)
        XCTAssertTrue(readyKey.canLoad)
        XCTAssertFalse(missingKey.canLoad)
    }

    @MainActor
    func test_image_returnsNil_whenRecordIsNotProxyPlayable() async {
        let service = ProxyThumbnailService(generator: StubProxyThumbnailGenerator(image: NSImage(size: .init(width: 10, height: 10))))
        let image = await service.image(
            for: makeRecord(status: .queued, proxyRelativePath: nil),
            projectRoot: URL(fileURLWithPath: "/project")
        )

        XCTAssertNil(image)
    }

    @MainActor
    func test_image_cachesResult_andOnlyCallsGeneratorOnce() async {
        // Arrange: a generator that counts invocations and always returns an image.
        let counter = GeneratorCallCounter()
        let testImage = NSImage(size: .init(width: 16, height: 9))
        let generator = CountingProxyThumbnailGenerator(counter: counter, image: testImage)
        let service = ProxyThumbnailService(generator: generator)

        let record = makeRecord()
        let projectRoot = URL(fileURLWithPath: "/project")

        // Act: two requests with the same effective key.
        let first = await service.image(for: record, projectRoot: projectRoot)
        let second = await service.image(for: record, projectRoot: projectRoot)

        // Assert: generator called exactly once; both calls return the same image.
        let callCount = await counter.count
        XCTAssertEqual(callCount, 1, "Generator should be called only once for the same cache key")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertIdentical(first, second, "Both calls should return the exact cached NSImage instance")
    }

    @MainActor
    func test_image_nilResult_isNotCached_andRetrySucceeds() async {
        // Arrange: generator returns nil on the first call, then a valid image on the second.
        let testImage = NSImage(size: .init(width: 16, height: 9))
        let generator = ScriptedProxyThumbnailGenerator(responses: [nil, testImage])
        let service = ProxyThumbnailService(generator: generator)

        let record = makeRecord()
        let projectRoot = URL(fileURLWithPath: "/project")

        // Act: first call encounters a generation failure; second call should retry.
        let first = await service.image(for: record, projectRoot: projectRoot)
        let second = await service.image(for: record, projectRoot: projectRoot)

        // Assert: nil was not cached, so the generator is invoked a second time and succeeds.
        let callCount = await generator.callCount
        XCTAssertNil(first, "A nil generation result should propagate to the caller")
        XCTAssertNotNil(second, "A retry after nil should attempt generation again and succeed")
        XCTAssertEqual(callCount, 2, "Generator should be called twice: once for nil, once for the retry")
    }
}
