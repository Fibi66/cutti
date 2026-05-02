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

enum MediaCoreError: Error {
    case recordNotFound(UUID)
}

protocol ProxyTranscoding: Sendable {
    func transcode(sourceURL: URL, destinationURL: URL) async -> TranscodeResult
}

struct MediaCore: Sendable {
    let store: ProjectStore
    let analyzer: any AssetAnalyzing
    let primaryTranscoder: any ProxyTranscoding
    let fallbackTranscoder: (any ProxyTranscoding)?

    func importLocalVideo(url: URL) async throws -> UUID {
        let fingerprint = try makeFingerprint(for: url)
        let analysis = try await analyzer.analyze(url: url)
        let mediaId = UUID()
        let proxyURL = store.proxyURL(for: mediaId)

        var manifest = try store.loadManifest()
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
        manifest.media.append(record)
        try store.saveManifest(manifest)

        switch await primaryTranscoder.transcode(sourceURL: url, destinationURL: proxyURL) {
        case .success:
            record.status = .ready
        case .fallbackEligibleFailure:
            guard let fallbackTranscoder else {
                record.status = .failed
                record.errorMessage = L("Primary transcoder failed and no fallback is configured")
                try update(record: record)
                return mediaId
            }
            // NOTE: Resolution asymmetry — the fallback (ffmpeg) scales to a 1280×720
            // ceiling; the primary (AVProxyTranscoder) preserves source resolution.
            // This is an intentional trade-off for encode speed and file-size on
            // high-res sources. See FFmpegProxyFallback.makeArguments for details.
            let fallbackResult = await fallbackTranscoder.transcode(sourceURL: url, destinationURL: proxyURL)
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

        try update(record: record)
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

        var manifest = try store.loadManifest()
        manifest.media.append(record)
        try store.saveManifest(manifest)
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

    private func update(record: MediaAssetRecord) throws {
        var manifest = try store.loadManifest()
        guard let index = manifest.media.firstIndex(where: { $0.id == record.id }) else {
            throw MediaCoreError.recordNotFound(record.id)
        }
        manifest.media[index] = record
        try store.saveManifest(manifest)
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
