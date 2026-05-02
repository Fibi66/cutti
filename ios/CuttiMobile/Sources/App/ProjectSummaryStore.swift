import Foundation
import UIKit
import AVFoundation
import CuttiKit

/// Async per-project summary (thumbnail + duration + clip count) used
/// by the project dashboard cards. Reads `media/manifest.json` +
/// `media/session.json` + `media/ios-session.json` directly without
/// opening the project, so listing stays cheap on cold launch.
///
/// Thumbnails are cached in memory (NSCache) and persisted to
/// `media/dashboard-thumbnail.jpg` inside each project so repeat
/// launches are near-instant. The persisted image is invalidated
/// when the project's manifest is newer than the thumbnail file —
/// a cheap staleness check that avoids full content hashing.
@MainActor
final class ProjectSummaryStore: ObservableObject {
    static let shared = ProjectSummaryStore()

    struct Summary: Equatable {
        var durationSeconds: Double
        var clipCount: Int
        var thumbnail: UIImage?
    }

    @Published private(set) var summaries: [UUID: Summary] = [:]
    private var inFlight: Set<UUID> = []
    private let memoryCache = NSCache<NSString, UIImage>()

    func summary(for id: UUID) -> Summary? { summaries[id] }

    /// Kick off (or no-op if already in flight) a background compute.
    func prime(projectID: UUID, projectRoot: URL) {
        if summaries[projectID] != nil || inFlight.contains(projectID) { return }
        inFlight.insert(projectID)
        Task.detached(priority: .utility) { [weak self] in
            let result = await ProjectSummaryStore.compute(projectRoot: projectRoot)
            await MainActor.run {
                if let self {
                    if let t = result.thumbnail {
                        self.memoryCache.setObject(t, forKey: projectRoot.path as NSString)
                    }
                    self.summaries[projectID] = result
                    self.inFlight.remove(projectID)
                }
            }
        }
    }

    private static func compute(projectRoot: URL) async -> Summary {
        let store = ProjectStore(projectRoot: projectRoot)
        let session = store.loadSessionState()
        let manifest = (try? store.loadManifest()) ?? MediaManifest()

        // Duration + clip count: walk the persisted primary video
        // track. If a project hasn't been edited yet fall back to the
        // manifest's media durations.
        var duration: Double = 0
        var clipCount: Int = 0
        if let tracks = session.currentTracks {
            for t in tracks where t.kind == "video" {
                for s in t.segments {
                    let d = max(0, s.endSeconds - s.startSeconds)
                    duration += d
                }
                clipCount = t.segments.count
                break
            }
        }
        if duration == 0 {
            duration = manifest.media.reduce(0) { $0 + ($1.analysis?.durationSeconds ?? 0) }
        }

        // Thumbnail: prefer ios-session coverTimeSeconds mapped through
        // the first video segment; else first segment start; else the
        // first media asset at t=0.
        let thumb = await loadOrGenerateThumbnail(
            projectRoot: projectRoot,
            manifest: manifest,
            session: session
        )

        return Summary(
            durationSeconds: duration,
            clipCount: clipCount,
            thumbnail: thumb
        )
    }

    private static func loadOrGenerateThumbnail(
        projectRoot: URL,
        manifest: MediaManifest,
        session: EditorSessionState
    ) async -> UIImage? {
        let fm = FileManager.default
        let manifestURL = projectRoot.appending(path: "media/manifest.json")
        let thumbURL = projectRoot.appending(path: "media/dashboard-thumbnail.jpg")
        let manifestDate = (try? fm.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date) ?? .distantPast
        let thumbDate = (try? fm.attributesOfItem(atPath: thumbURL.path)[.modificationDate] as? Date) ?? .distantPast

        if fm.fileExists(atPath: thumbURL.path), thumbDate >= manifestDate,
           let data = try? Data(contentsOf: thumbURL),
           let img = UIImage(data: data) {
            return img
        }

        // Generate afresh. Pick the first playable segment on the
        // primary video track (else the first media asset), at the
        // cover time or t=0.
        let mediaByID = Dictionary(uniqueKeysWithValues: manifest.media.map { ($0.id, $0) })
        let ios = IOSSessionStore.load(projectRoot: projectRoot)

        var sourceURL: URL?
        var atSeconds: Double = 0
        if let tracks = session.currentTracks,
           let primary = tracks.first(where: { $0.kind == "video" }),
           let first = primary.segments.first,
           let asset = mediaByID[first.sourceVideoID] {
            sourceURL = resolveURL(for: asset, projectRoot: projectRoot)
            atSeconds = ios.coverTimeSeconds ?? first.startSeconds
        } else if let first = manifest.media.first {
            sourceURL = resolveURL(for: first, projectRoot: projectRoot)
            atSeconds = 0
        }
        guard let sourceURL else { return nil }

        let asset = AVURLAsset(url: sourceURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: max(0, atSeconds), preferredTimescale: 600)
        guard let cg = try? await gen.image(at: time).image else { return nil }
        let img = UIImage(cgImage: cg)
        if let data = img.jpegData(compressionQuality: 0.7) {
            try? data.write(to: thumbURL, options: .atomic)
        }
        return img
    }

    private static func resolveURL(for asset: MediaAssetRecord, projectRoot: URL) -> URL {
        if let rel = asset.derived.proxyRelativePath {
            let u = projectRoot.appending(path: rel)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return URL(fileURLWithPath: asset.sourcePath)
    }
}
