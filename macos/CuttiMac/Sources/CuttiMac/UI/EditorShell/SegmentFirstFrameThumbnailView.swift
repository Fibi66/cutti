import SwiftUI
import AVFoundation
import CuttiKit

/// Renders a single frame from a media asset at a given source-time.
/// Used by the AI chat attachment chip strip to show "what segment am I
/// attaching?" without spinning up the full `PosterThumbnailView` /
/// `ProxyThumbnailService` machinery (which is record-wide, not
/// time-targeted).
///
/// Resolves the backing URL from `MediaAssetRecord.derived.proxyRelativePath`
/// (preferred) and falls back to the original `sourcePath`. Frame is
/// cached in-memory per `(url, seconds, size)` via a tiny shared cache
/// so scrolling a chip strip doesn't re-decode on every layout pass.
struct SegmentFirstFrameThumbnailView: View {
    let sourceVideoID: UUID
    let sourceStartSeconds: Double
    let records: [MediaAssetRecord]
    let projectRoot: URL?
    let size: CGSize

    @State private var image: NSImage?

    init(
        sourceVideoID: UUID,
        sourceStartSeconds: Double,
        records: [MediaAssetRecord],
        projectRoot: URL?,
        size: CGSize = CGSize(width: 62, height: 40)
    ) {
        self.sourceVideoID = sourceVideoID
        self.sourceStartSeconds = sourceStartSeconds
        self.records = records
        self.projectRoot = projectRoot
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: size.width, maxHeight: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "film")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.08))
        )
        .task(id: cacheKey) {
            await loadFrame()
        }
    }

    private var resolvedURL: URL? {
        guard let record = records.first(where: { $0.id == sourceVideoID }) else { return nil }
        if let proxyPath = record.derived.proxyRelativePath, let root = projectRoot {
            return root.appending(path: proxyPath)
        }
        return URL(fileURLWithPath: record.sourcePath)
    }

    private var cacheKey: String {
        "\(sourceVideoID.uuidString)|\(sourceStartSeconds)|\(Int(size.width))x\(Int(size.height))"
    }

    private func loadFrame() async {
        if let cached = SegmentFirstFrameCache.shared.image(forKey: cacheKey) {
            self.image = cached
            return
        }
        guard let url = resolvedURL else { return }
        let loaded = await Self.extract(from: url, at: sourceStartSeconds, size: size)
        guard let loaded, !Task.isCancelled else { return }
        SegmentFirstFrameCache.shared.set(loaded, forKey: cacheKey)
        self.image = loaded
    }

    private static func extract(from url: URL, at seconds: Double, size: CGSize) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            let natural = CGSize(width: cgImage.width, height: cgImage.height)
            return NSImage(cgImage: cgImage, size: natural)
        } catch {
            return nil
        }
    }
}

/// Small thread-safe NSCache wrapper. Keeps recent first-frame thumbnails
/// in memory so the chip strip doesn't re-decode on every VM update.
/// NSCache itself is thread-safe; marking this Sendable lets us share a
/// process-wide `shared` instance under Swift 6 strict concurrency.
private final class SegmentFirstFrameCache: @unchecked Sendable {
    static let shared = SegmentFirstFrameCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 64
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
