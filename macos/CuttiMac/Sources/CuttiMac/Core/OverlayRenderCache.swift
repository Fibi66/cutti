import Foundation
import CuttiKit

/// On-disk, content-addressable cache for AI-generated Remotion
/// overlays.
///
/// The contract:
/// - `media/overlays/<cacheKey>.mov` stores the rendered ProRes 4444
///   file for a given `OverlayRenderSpec`. Identical specs share the
///   same file.
/// - `media/overlays/index.json` maps `cacheKey → imported mediaID` so
///   the Mac app reuses the same `MediaAssetRecord` across sessions
///   instead of re-importing the same bytes every time.
///
/// `resolveMediaID(for:)` is the single entry-point used by both the
/// initial `generateOverlay` path and the Inspector-driven
/// `updateOverlayProps` path: it returns the mediaID of the imported
/// asset, rendering + importing on cache miss.
actor OverlayRenderCache {
    let renderer: RemotionOverlayRendering
    let projectRoot: URL
    let mediaCore: any MediaCoreImporting

    private var index: [String: UUID] = [:]
    private var indexLoaded = false

    init(renderer: RemotionOverlayRendering, projectRoot: URL, mediaCore: any MediaCoreImporting) {
        self.renderer = renderer
        self.projectRoot = projectRoot
        self.mediaCore = mediaCore
    }

    /// Absolute URL of the `.mov` for `spec`. Not guaranteed to exist.
    nonisolated func movURL(for spec: OverlayRenderSpec) -> URL {
        projectRoot.appending(path: "media/overlays/\(spec.cacheKey).mov")
    }

    /// Returns the mediaID of the imported asset for `spec`, rendering
    /// + importing on cache miss. Safe to call concurrently; the actor
    /// serializes index mutations but renders/imports run on the
    /// caller's continuation so multiple distinct specs can render in
    /// parallel from the caller's perspective.
    func resolveMediaID(for spec: OverlayRenderSpec) async throws -> UUID {
        await loadIndexIfNeeded()
        if let cached = index[spec.cacheKey] {
            // Trust-but-don't-verify: if the mov file is gone the next
            // export will re-render. We still consider the mediaID
            // stable for UI continuity.
            return cached
        }
        let outputURL = movURL(for: spec)
        let fm = FileManager.default
        try fm.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fm.fileExists(atPath: outputURL.path) {
            let request = RemotionRenderRequest(
                templateID: spec.templateID,
                propsJSON: spec.propsJSON,
                durationSeconds: spec.durationSeconds,
                width: spec.width,
                height: spec.height,
                fps: spec.fps
            )
            try await renderer.render(request, outputURL: outputURL)
        }
        let mediaID = try await mediaCore.importLocalVideo(url: outputURL)
        index[spec.cacheKey] = mediaID
        try persistIndex()
        return mediaID
    }

    // MARK: - index persistence

    private var indexURL: URL {
        projectRoot.appending(path: "media/overlays/index.json")
    }

    private func loadIndexIfNeeded() async {
        if indexLoaded { return }
        indexLoaded = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: UUID].self, from: data) else {
            return
        }
        self.index = decoded
    }

    private func persistIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: indexURL, options: .atomic)
    }
}
