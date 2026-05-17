import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import CuttiKit

enum TranscodeResult {
    case success
    case fallbackEligibleFailure(String)
    case failure(String)
}

enum MediaCoreError: Error, LocalizedError {
    case recordNotFound(UUID)

    var errorDescription: String? {
        switch self {
        // We deliberately don't include the UUID — it's a developer
        // identifier, not something the user can act on.
        case .recordNotFound:
            return L("That media clip is no longer in the project.")
        }
    }
}

/// User-facing reasons an import was rejected before any work happened.
/// Cancellation is reported separately via `CancellationError`.
enum ImportError: Error, LocalizedError, Sendable {
    case insufficientDiskSpace(neededBytes: Int64, freeBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let needed, let free):
            let neededMB = max(1, needed / 1_000_000)
            let freeMB = max(0, free / 1_000_000)
            return "Not enough free disk space to transcode this video. " +
                   "Estimated \(neededMB) MB needed, \(freeMB) MB free."
        }
    }
}

/// Coarse-grained phase reported back to the UI while an import runs.
enum ImportPhase: Sendable, Equatable {
    /// Hashing source + reading metadata. Sub-second on most files.
    case preparing
    /// Loading AVAsset tracks. Long on non-faststart sources over USB.
    case analyzing
    /// Held by the concurrency gate behind another in-flight import.
    case waiting
    /// AVAssetExportSession (or ffmpeg fallback) actively encoding.
    case transcoding
}

protocol ProxyTranscoding: Sendable {
    /// Transcode `sourceURL` into a proxy at `destinationURL`, periodically
    /// invoking `progress` with the fraction complete in `0.0...1.0`.
    /// Implementations should respect `Task.isCancelled` and stop work as
    /// soon as cancellation is observed.
    func transcode(
        sourceURL: URL,
        destinationURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async -> TranscodeResult
}

extension ProxyTranscoding {
    /// Convenience overload for callers that don't care about progress
    /// (test wiring, simple call sites). Forwards a no-op closure.
    func transcode(sourceURL: URL, destinationURL: URL) async -> TranscodeResult {
        await transcode(sourceURL: sourceURL, destinationURL: destinationURL, progress: { _ in })
    }
}

struct MediaCore: Sendable {
    let store: ProjectStore
    let analyzer: any AssetAnalyzing
    let primaryTranscoder: any ProxyTranscoding
    let fallbackTranscoder: (any ProxyTranscoding)?
    /// Serialises manifest read-modify-write across concurrent imports
    /// so they don't clobber each other. When nil (legacy / test wiring),
    /// `MediaCore` falls back to direct `store.load+save` —
    /// race-on-concurrent-imports is then the caller's problem.
    let manifestGate: ManifestMutationGate?
    /// Bounds simultaneous transcodes. When nil, all imports race to the
    /// transcoder at once (legacy behaviour).
    let concurrencyGate: ImportConcurrencyGate?

    init(
        store: ProjectStore,
        analyzer: any AssetAnalyzing,
        primaryTranscoder: any ProxyTranscoding,
        fallbackTranscoder: (any ProxyTranscoding)?,
        manifestGate: ManifestMutationGate? = nil,
        concurrencyGate: ImportConcurrencyGate? = nil
    ) {
        self.store = store
        self.analyzer = analyzer
        self.primaryTranscoder = primaryTranscoder
        self.fallbackTranscoder = fallbackTranscoder
        self.manifestGate = manifestGate
        self.concurrencyGate = concurrencyGate
    }

    func importLocalVideo(
        url: URL,
        progress: @Sendable @escaping (ImportPhase, Double) -> Void = { _, _ in }
    ) async throws -> UUID {
        progress(.preparing, 0)
        let fingerprint = try makeFingerprint(for: url)
        try Task.checkCancellation()

        progress(.analyzing, 0)
        let analysis = try await analyzer.analyze(url: url)
        try Task.checkCancellation()

        let mediaId = UUID()
        let proxyURL = store.proxyURL(for: mediaId)

        // Disk-space precheck before we write any record so a doomed
        // import never leaves a zombie `.transcoding` row behind. The
        // planner decides whether we passthrough (output ≈ source size)
        // or re-encode to ProRes 422 (output ≈ width × height × fps).
        // Returns 0 if it can't make a useful guess (audio-only sources,
        // missing dimensions); we skip the check rather than reject in
        // those degenerate cases.
        let transcodePlan = await ProxyTranscodePlanner.plan(url: url, analysis: analysis)
        let estimatedBytes = transcodePlan.estimatedOutputBytes
        if estimatedBytes > 0,
           let freeBytes = ProxyDiskSpaceEstimator.freeBytes(forVolumeContaining: store.projectRoot),
           freeBytes < estimatedBytes {
            throw ImportError.insufficientDiskSpace(
                neededBytes: estimatedBytes,
                freeBytes: freeBytes
            )
        }

        var record = MediaAssetRecord(
            id: mediaId,
            sourcePath: url.path,
            fingerprint: fingerprint,
            status: .transcoding,
            analysis: analysis,
            derived: .init(
                proxyRelativePath: AppleSiliconProxySettings.profile.relativeProxyPath(for: mediaId),
                thumbnailsReady: false,
                waveformsReady: false
            ),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
        let initialRecord = record
        try await mutateManifest { manifest in
            manifest.media.append(initialRecord)
        }

        // Acquire the concurrency permit, then transcode. The gate's
        // `withPermit` rethrows `CancellationError` if our task was
        // cancelled while waiting in the queue, in which case we clean
        // up the optimistic record below.
        do {
            progress(.waiting, 0)
            let primaryResult: TranscodeResult = try await runWithConcurrencyLimit { @Sendable in
                progress(.transcoding, 0)
                return await primaryTranscoder.transcode(
                    sourceURL: url,
                    destinationURL: proxyURL,
                    progress: { fraction in progress(.transcoding, fraction) }
                )
            }

            try await honourCancellation(mediaId: mediaId, proxyURL: proxyURL)

            switch primaryResult {
            case .success:
                record.status = .ready
            case .fallbackEligibleFailure:
                guard let fallbackTranscoder else {
                    record.status = .failed
                    record.errorMessage = L("Primary transcoder failed and no fallback is configured")
                    try await update(record: record)
                    return mediaId
                }
                // NOTE: Resolution asymmetry — the fallback (ffmpeg) scales to a 1280×720
                // ceiling; the primary (AVProxyTranscoder) preserves source resolution.
                // This is an intentional trade-off for encode speed and file-size on
                // high-res sources. See FFmpegProxyFallback.makeArguments for details.
                let fallbackResult = try await runWithConcurrencyLimit { @Sendable in
                    return await fallbackTranscoder.transcode(
                        sourceURL: url,
                        destinationURL: proxyURL,
                        progress: { fraction in progress(.transcoding, fraction) }
                    )
                }
                try await honourCancellation(mediaId: mediaId, proxyURL: proxyURL)
                switch fallbackResult {
                case .success:
                    record.status = .ready
                    record.usedFallbackTranscoder = true
                case .fallbackEligibleFailure(let message), .failure(let message):
                    record.status = .failed
                    record.errorMessage = message
                }
            case .failure(let message):
                record.status = .failed
                record.errorMessage = message
            }
        } catch is CancellationError {
            try? await cleanupCancelledImport(mediaId: mediaId, proxyURL: proxyURL)
            throw CancellationError()
        }

        try await update(record: record)
        return mediaId
    }

    func relinkOriginal(mediaId: UUID, newURL: URL) throws {
        var manifest = try store.loadManifest()
        guard let index = manifest.media.firstIndex(where: { $0.id == mediaId }) else {
            throw MediaCoreError.recordNotFound(mediaId)
        }

        // Compute fingerprint of new file
        let newFingerprint = try makeFingerprint(for: newURL)

        manifest.media[index].sourcePath = newURL.path
        manifest.media[index].fingerprint = newFingerprint
        manifest.media[index].status = .queued
        manifest.media[index].errorMessage = nil
        try store.saveManifest(manifest)
    }

    func validateSources() throws {
        var manifest = try store.loadManifest()
        var modified = false

        for index in manifest.media.indices {
            let record = manifest.media[index]
            let sourceURL = URL(fileURLWithPath: record.sourcePath)

            // Check if source file exists
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                manifest.media[index].status = .missing
                manifest.media[index].errorMessage = L("Original file is missing. Please relink it.")
                modified = true
                continue
            }

            // Check if fingerprint changed
            do {
                let currentFingerprint = try makeFingerprint(for: sourceURL)
                if currentFingerprint != record.fingerprint {
                    manifest.media[index].fingerprint = currentFingerprint
                    manifest.media[index].status = .queued
                    manifest.media[index].errorMessage = L("Source changed on disk. Rebuild the proxy.")
                    modified = true
                }
            } catch {
                // If we can't read the file for fingerprinting, mark as missing
                manifest.media[index].status = .missing
                manifest.media[index].errorMessage = L("Original file is missing. Please relink it.")
                modified = true
            }
        }

        if modified {
            try store.saveManifest(manifest)
        }
    }

    func importLocalImage(url: URL) async throws -> UUID {
        let fingerprint = try makeFingerprint(for: url)
        let mediaId = UUID()

        // Stills have no duration / fps / audio; width + height we can
        // read cheaply via ImageIO. Kept as a full AnalysisSummary (with
        // durationSeconds = 0) so existing metadata UI continues to
        // work without branching on kind everywhere. The sanitizer's
        // `sourceDuration > 0` guard handles the zero safely.
        let (width, height) = Self.readImageDimensions(url: url) ?? (0, 0)
        let analysis = AnalysisSummary(
            durationSeconds: 0,
            width: width,
            height: height,
            nominalFPS: 0,
            hasAudio: false
        )

        let record = MediaAssetRecord(
            id: mediaId,
            sourcePath: url.path,
            fingerprint: fingerprint,
            status: .ready,
            analysis: analysis,
            derived: .init(
                proxyRelativePath: nil,
                thumbnailsReady: true,
                waveformsReady: true
            ),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            kind: .image
        )

        try await mutateManifest { manifest in
            manifest.media.append(record)
        }
        return mediaId
    }

    /// Reads the pixel dimensions of an image file using ImageIO.
    /// Returns nil if the file is unreadable — the caller falls back
    /// to (0, 0) so import still succeeds; the compositor's own
    /// image-loader handles bad files at render time.
    private static func readImageDimensions(url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (w, h)
    }

    private func update(record: MediaAssetRecord) async throws {
        try await mutateManifest { manifest in
            guard let index = manifest.media.firstIndex(where: { $0.id == record.id }) else {
                throw MediaCoreError.recordNotFound(record.id)
            }
            manifest.media[index] = record
        }
    }

    /// Throws `CancellationError` if the parent task has been cancelled
    /// since the transcoder finished. Cleans up the partial proxy file
    /// and the optimistic manifest record before throwing so the user
    /// is not left with zombie state.
    private func honourCancellation(mediaId: UUID, proxyURL: URL) async throws {
        guard Task.isCancelled else { return }
        try? await cleanupCancelledImport(mediaId: mediaId, proxyURL: proxyURL)
        throw CancellationError()
    }

    private func cleanupCancelledImport(mediaId: UUID, proxyURL: URL) async throws {
        try? FileManager.default.removeItem(at: proxyURL)
        try await mutateManifest { manifest in
            manifest.media.removeAll { $0.id == mediaId }
        }
    }

    /// Runs `body` under the manifest gate when one is configured,
    /// otherwise falls back to a direct load-modify-save against the
    /// store. Tests that construct `MediaCore` without a gate get the
    /// legacy behaviour transparently.
    private func mutateManifest<T: Sendable>(
        _ body: @Sendable (inout MediaManifest) throws -> T
    ) async throws -> T {
        if let manifestGate {
            return try await manifestGate.mutate(body)
        }
        var manifest = try store.loadManifest()
        let result = try body(&manifest)
        try store.saveManifest(manifest)
        return result
    }

    /// Acquires a concurrency permit when the gate is configured;
    /// otherwise runs `body` immediately.
    private func runWithConcurrencyLimit<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        if let concurrencyGate {
            return try await concurrencyGate.withPermit(body)
        }
        return try await body()
    }

    private func makeFingerprint(for url: URL) throws -> SourceFingerprint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = Int64(values.fileSize ?? 0)
        let rawModifiedAt = values.contentModificationDate ?? .distantPast

        // Truncate to second precision to avoid JSON encoding/decoding precision loss
        let modifiedAt = Date(timeIntervalSince1970: floor(rawModifiedAt.timeIntervalSince1970))

        // Compute real SHA256 prefix from first chunk only (1 MB max)
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        let chunkSize = 1024 * 1024 // 1 MB
        let chunk = try fileHandle.read(upToCount: chunkSize) ?? Data()
        let hash = SHA256.hash(data: chunk)
        let sha256Prefix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()

        return SourceFingerprint(fileSize: fileSize, modifiedAt: modifiedAt, sha256Prefix: sha256Prefix)
    }
}
