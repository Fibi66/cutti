import AVFoundation
import AppKit
import CoreMedia
import Foundation
import CuttiKit

// MARK: - Protocol

/// Generates a thumbnail image from a proxy media file at a given time.
protocol ProxyThumbnailGenerating: Sendable {
    func generateImage(proxyURL: URL, at time: CMTime) async -> NSImage?
}

// MARK: - Live generator

/// Production implementation that uses `AVAssetImageGenerator`.
struct AVAssetProxyThumbnailGenerator: ProxyThumbnailGenerating {
    func generateImage(proxyURL: URL, at time: CMTime) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: proxyURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true

            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                return nil
            }
            return NSImage(cgImage: cgImage, size: .zero)
        }.value
    }
}

// MARK: - Service

/// Shared service that generates and caches proxy poster thumbnails.
///
/// Each call to `image(for:projectRoot:)` checks an in-memory cache keyed by
/// the record's `RequestKey` before delegating to the underlying generator.
/// This prevents redundant decoding when many views request the same frame.
///
/// In addition, an **in-flight deduplication** map ensures that if two callers
/// concurrently request the same thumbnail, only one generator invocation is
/// started; the second caller awaits the same `Task` and gets the same result.
/// A `nil` result is never stored in the cache, so a later retry will attempt
/// generation again.
@MainActor
final class ProxyThumbnailService {

    // MARK: Request key

    struct RequestKey: Equatable, Hashable {
        let recordID: UUID
        let status: MediaStatus
        let kind: MediaKind
        let sourcePath: String
        let proxyRelativePath: String?
        let projectRootPath: String?

        /// `true` when the record is `ready` and has enough info to
        /// render a poster. Videos need a proxy under the project
        /// root; still images load directly from their original
        /// `sourcePath` (no proxy, no project root required).
        var canLoad: Bool {
            guard status == .ready else { return false }
            switch kind {
            case .image:
                return !sourcePath.isEmpty
            case .video:
                return proxyRelativePath != nil && projectRootPath != nil
            }
        }
    }

    // MARK: Singleton

    static let shared = ProxyThumbnailService(generator: AVAssetProxyThumbnailGenerator())

    // MARK: Init

    private let generator: any ProxyThumbnailGenerating
    private var cache: [RequestKey: NSImage] = [:]

    /// Tracks in-progress generation tasks so that concurrent requests for the
    /// same key share a single generator invocation rather than spawning duplicates.
    private var inFlight: [RequestKey: Task<NSImage?, Never>] = [:]

    init(generator: any ProxyThumbnailGenerating) {
        self.generator = generator
    }

    // MARK: API

    /// Builds a `RequestKey` for the given record and optional project root.
    /// When `projectRoot` is `nil` the key's `projectRootPath` is also `nil`,
    /// which causes `canLoad` to return `false` without extra branching at the call site.
    static func requestKey(for record: MediaAssetRecord, projectRoot: URL?) -> RequestKey {
        RequestKey(
            recordID: record.id,
            status: record.status,
            kind: record.kind,
            sourcePath: record.sourcePath,
            proxyRelativePath: record.derived.proxyRelativePath,
            projectRootPath: projectRoot.map { $0.standardizedFileURL.path }
        )
    }

    /// Returns a cached thumbnail, or generates and caches one on first call.
    /// Returns `nil` when the record is not proxy-playable.
    ///
    /// Concurrent requests for the same `RequestKey` are deduplicated: the second
    /// (and any further) caller awaits the already-running `Task` instead of
    /// starting a new generator invocation.
    func image(for record: MediaAssetRecord, projectRoot: URL?) async -> NSImage? {
        let key = Self.requestKey(for: record, projectRoot: projectRoot)

        guard key.canLoad else { return nil }

        // Fast path: already cached.
        if let cached = cache[key] {
            return cached
        }

        // Dedup path: a generation for this key is already running.
        if let existing = inFlight[key] {
            return await existing.value
        }

        // Slow path: kick off a new generation task. Images load directly
        // via NSImage; videos go through the AVAssetImageGenerator pipeline.
        let task: Task<NSImage?, Never>
        switch record.kind {
        case .image:
            let sourceURL = URL(fileURLWithPath: record.sourcePath)
            task = Task<NSImage?, Never> {
                await Task.detached(priority: .utility) {
                    NSImage(contentsOf: sourceURL)
                }.value
            }
        case .video:
            guard let proxyRelativePath = key.proxyRelativePath,
                  let projectRoot else {
                return nil
            }
            let proxyURL = projectRoot.appending(path: proxyRelativePath)
            let frameSeconds = min(record.analysis?.durationSeconds ?? 0.5, 0.5)
            let frameTime = CMTime(seconds: frameSeconds, preferredTimescale: 600)
            task = Task<NSImage?, Never> {
                await self.generator.generateImage(proxyURL: proxyURL, at: frameTime)
            }
        }
        inFlight[key] = task

        let generated = await task.value

        // We're back on @MainActor; clean up the in-flight entry unconditionally.
        inFlight[key] = nil

        // Only cache successful results — a nil result must not suppress retries.
        if let generated {
            cache[key] = generated
        }

        return generated
    }
}
