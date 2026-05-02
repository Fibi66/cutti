// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

// MARK: - Segment Filmstrip (thumbnails for a specific time range)

/// Renders a still-image asset as a fill-scaled thumbnail on the
/// timeline. Loads via the shared `ProxyThumbnailService` so the
/// decoded `NSImage` is cached and deduplicated across every place
/// (library, V1, overlay pill) that renders the same record.
struct ImageAssetThumbnail: View {
    let record: MediaAssetRecord
    let projectRoot: URL?

    @State private var image: NSImage?

    var body: some View {
        let token = ProxyThumbnailService.requestKey(for: record, projectRoot: projectRoot)
        ZStack {
            // Letterbox background so aspect-mismatched images read as
            // "full image inside a pill" rather than a cropped fill.
            Rectangle()
                .fill(Color.black.opacity(0.6))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: token) {
            await load(token: token)
        }
    }

    @MainActor
    private func load(token: ProxyThumbnailService.RequestKey) async {
        image = nil
        guard token.canLoad else { return }
        let loaded = await ProxyThumbnailService.shared.image(for: record, projectRoot: projectRoot)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

/// Tiny process-wide cache of the *display* aspect ratio (w/h, after
/// preferred transform) per video URL. Populated on first filmstrip
/// render for an asset and reused so portrait / square clips don't
/// pay a track-load tax on every body evaluation.
@MainActor
private enum FilmstripAspectCache {
    static var ratios: [String: CGFloat] = [:]
}

struct SegmentFilmstrip: View {
    let videoURL: URL
    let startSeconds: Double
    let endSeconds: Double
    let width: CGFloat
    let height: CGFloat

    @State private var thumbnails: [NSImage] = []
    @State private var aspectRatio: CGFloat = 16.0 / 9.0

    private var thumbWidth: CGFloat { max(1, height * aspectRatio) }
    private var thumbCount: Int { max(1, Int(width / thumbWidth) + 1) }

    var body: some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                // Placeholder
                Color.gray.opacity(0.2)
                    .frame(width: width, height: height)
            } else {
                // Render each thumbnail at its natural (thumbWidth × height)
                // cell so thumbnails stay visually identical across pills
                // of different durations. The outer .frame + .clipped()
                // crops any overflow from the '+1' extra thumbnail, and
                // during a zoom-in a brief gap on the right edge is fine
                // (regen debounce is 140ms).
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: thumbWidth, height: height)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
        // Bucket width to 32pt steps: moving a pill by one pixel during a
        // pan/zoom gesture must not re-fire AVAssetImageGenerator. A 32pt
        // bucket keeps thumbnail density visually stable while letting
        // mid-gesture width jitter reuse the same task id.
        .task(id: "\(videoURL.path)_\(String(format: "%.1f", startSeconds))_\(String(format: "%.1f", endSeconds))_\(Int(width / 32))") {
            // Debounce: during a zoom animation the width bucket can
            // tick through several values in ~200 ms. Sleeping briefly
            // at the start means intermediate tasks cancel each other
            // before any generator work fires — only the final width
            // actually decodes frames. Much lighter than the previous
            // approach of clearing `thumbnails` and restarting
            // AVAssetImageGenerator on every tick.
            //
            // Intentionally NOT blanking `thumbnails` here: letting the
            // old (stretched) frames stay visible until new ones
            // arrive hides the regen latency that made zoom feel
            // laggy.
            try? await Task.sleep(nanoseconds: 140_000_000)
            if Task.isCancelled { return }
            await resolveAspectRatio()
            await generateThumbnails()
        }
    }

    private func resolveAspectRatio() async {
        let key = videoURL.path
        if let cached = await MainActor.run(body: { FilmstripAspectCache.ratios[key] }) {
            await MainActor.run { self.aspectRatio = cached }
            return
        }
        let asset = AVURLAsset(url: videoURL)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let applied = natural.applying(transform)
            let w = abs(applied.width)
            let h = abs(applied.height)
            guard w > 0, h > 0 else { return }
            let ratio = w / h
            await MainActor.run {
                FilmstripAspectCache.ratios[key] = ratio
                self.aspectRatio = ratio
            }
        } catch {
            // Leave the default 16:9 fallback in place.
        }
    }

    private func generateThumbnails() async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbWidth * 2, height: height * 2)

        let duration = endSeconds - startSeconds
        let interval = duration / Double(thumbCount)
        var results: [NSImage] = []

        for i in 0..<thumbCount {
            do {
                try Task.checkCancellation()
            } catch {
                return
            }
            let time = CMTime(seconds: startSeconds + interval * Double(i), preferredTimescale: 600)
            do {
                let (cgImage, _) = try await generator.image(at: time)
                // Use the cgImage's own pixel dimensions for the NSImage
                // size hint so SwiftUI's `.aspectRatio(.fit)` uses the
                // real frame aspect (not the assumed `thumbWidth/height`).
                // Prevents portrait/square videos from being squashed
                // into a 16:9 box while `aspectRatio` is still the
                // default.
                let size = NSSize(width: cgImage.width, height: cgImage.height)
                results.append(NSImage(cgImage: cgImage, size: size))
            } catch {
                if error is CancellationError { return }
                print("⚠️ Filmstrip: failed frame at \(String(format: "%.1f", time.seconds))s: \(error.localizedDescription)")
            }
            // Give the cancellation signal a chance to propagate between
            // frames — without this yield a rapid zoom gesture queues up
            // many generators that all finish before the next task-id
            // change can fire.
            await Task.yield()
        }

        if Task.isCancelled { return }
        await MainActor.run {
            self.thumbnails = results
        }
    }
}
