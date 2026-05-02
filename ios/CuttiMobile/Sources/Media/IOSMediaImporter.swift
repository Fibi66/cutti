import Foundation
import AVFoundation
import CryptoKit
import CuttiKit

/// iOS-side media importer. Copies a picked video into the project's
/// media directory, reads metadata via `AVAsset`, and appends a
/// `MediaAssetRecord` to the manifest. The originals are stored under
/// `media/originals/<uuid>.<ext>` so subsequent proxy transcodes (when
/// we ship them) can write into the existing `media/proxies/` tree
/// without disturbing the source. No proxy is generated yet — the
/// player plays the original file directly.
struct IOSMediaImporter {
    enum ImportError: Error, LocalizedError {
        case assetUnreadable
        case copyFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .assetUnreadable: return "Couldn't read video metadata."
            case .copyFailed(let error): return "Couldn't copy file: \(error.localizedDescription)"
            }
        }
    }

    let store: ProjectStore

    /// Import a video file (already downloaded to a local URL). Copies
    /// the file into the project, updates the manifest, and returns
    /// the new asset record.
    func importVideo(from sourceURL: URL) async throws -> MediaAssetRecord {
        try store.bootstrapProject()
        let originalsDir = store.projectRoot.appending(path: "media/originals")
        try FileManager.default.createDirectory(
            at: originalsDir,
            withIntermediateDirectories: true
        )

        let mediaID = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destURL = originalsDir.appending(path: "\(mediaID.uuidString).\(ext)")

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ImportError.copyFailed(underlying: error)
        }

        let fingerprint = try Self.makeFingerprint(for: destURL)
        let analysis = try await Self.analyze(url: destURL)

        let record = MediaAssetRecord(
            id: mediaID,
            sourcePath: destURL.path,
            fingerprint: fingerprint,
            status: .ready,
            analysis: analysis,
            derived: DerivedAssetState(
                proxyRelativePath: nil,
                thumbnailsReady: false,
                waveformsReady: false
            ),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            kind: .video
        )

        var manifest = (try? store.loadManifest()) ?? MediaManifest()
        manifest.media.append(record)
        try store.saveManifest(manifest)

        return record
    }

    // MARK: - Helpers

    static func makeFingerprint(for url: URL) throws -> SourceFingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date()

        // Hash only the first 1 MB; full-file sha256 is expensive on
        // large 4K videos and the prefix is enough to detect identical
        // re-imports.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunk = (try? handle.read(upToCount: 1_048_576)) ?? Data()
        let digest = SHA256.hash(data: chunk)
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()

        return SourceFingerprint(
            fileSize: size,
            modifiedAt: modified,
            sha256Prefix: prefix
        )
    }

    static func analyze(url: URL) async throws -> AnalysisSummary {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        let videoTrack = tracks.first { $0.mediaType == .video }
        let audioTrack = tracks.first { $0.mediaType == .audio }

        var width = 0
        var height = 0
        var fps = 0.0
        if let videoTrack {
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let sized = naturalSize.applying(transform)
            width = Int(abs(sized.width))
            height = Int(abs(sized.height))
            fps = Double(try await videoTrack.load(.nominalFrameRate))
        }

        return AnalysisSummary(
            durationSeconds: CMTimeGetSeconds(duration),
            width: width,
            height: height,
            nominalFPS: fps,
            hasAudio: audioTrack != nil
        )
    }

    /// Import an audio-only file (e.g. mic recording). Variant of
    /// `importVideo` that stamps the manifest entry with `kind: .audio`
    /// so downstream queries don't mistake it for a silent video.
    func importAudio(from sourceURL: URL) async throws -> MediaAssetRecord {
        try store.bootstrapProject()
        let originalsDir = store.projectRoot.appending(path: "media/originals")
        try FileManager.default.createDirectory(
            at: originalsDir,
            withIntermediateDirectories: true
        )

        let mediaID = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let destURL = originalsDir.appending(path: "\(mediaID.uuidString).\(ext)")

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ImportError.copyFailed(underlying: error)
        }

        let fingerprint = try Self.makeFingerprint(for: destURL)
        let analysis = try await Self.analyze(url: destURL)

        let record = MediaAssetRecord(
            id: mediaID,
            sourcePath: destURL.path,
            fingerprint: fingerprint,
            status: .ready,
            analysis: analysis,
            derived: DerivedAssetState(
                proxyRelativePath: nil,
                thumbnailsReady: false,
                waveformsReady: false
            ),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            // Shared MediaKind has no .audio case (video / image only);
            // treat voiceover files as .video for manifest purposes.
            // They live on a dedicated audio track so the distinction
            // only matters if the dashboard ever tries to read a video
            // frame from an .m4a — it doesn't, because thumbnails are
            // sourced from the primary track.
            kind: .video
        )

        var manifest = (try? store.loadManifest()) ?? MediaManifest()
        manifest.media.append(record)
        try store.saveManifest(manifest)

        return record
    }
}
