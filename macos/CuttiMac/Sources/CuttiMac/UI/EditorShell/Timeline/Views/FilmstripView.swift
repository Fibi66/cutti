// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

// MARK: - Filmstrip View

struct FilmstripView: View {
    let videoURL: URL
    let duration: Double
    let segments: [TimelineSegment]
    let width: CGFloat
    let height: CGFloat
    let pointsPerSecond: CGFloat

    @State private var thumbnails: [(time: Double, image: NSImage)] = []

    private var thumbWidth: CGFloat { height * 16 / 9 }
    private var thumbCount: Int { max(1, Int(width / thumbWidth) + 1) }

    var body: some View {
        HStack(spacing: 0) {
            // Divide the available width evenly so mid-zoom (when
            // `thumbnails.count` still reflects the pre-zoom width) the
            // strip still covers the whole pill. When regen completes,
            // the new count lands and cell width snaps back to aspect.
            let cellWidth = thumbnails.isEmpty
                ? width
                : width / CGFloat(max(1, thumbnails.count))
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, thumb in
                Image(nsImage: thumb.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: cellWidth, height: height)
                    .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            if !segments.isEmpty {
                Canvas { context, size in
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(.black.opacity(0.5))
                    )
                    for segment in segments {
                        let x = CGFloat(quantizedSeconds(segment.range.startSeconds)) * pointsPerSecond
                        let w = CGFloat(quantizedSeconds(segment.durationSeconds)) * pointsPerSecond
                        context.blendMode = .destinationOut
                        context.fill(
                            Path(CGRect(x: x, y: 0, width: w, height: size.height)),
                            with: .color(.white)
                        )
                    }
                }
                .compositingGroup()
            }
        }
        // Bucket width to 32pt steps (same reasoning as SegmentFilmstrip):
        // pixel-level width changes during pan/zoom shouldn't re-fire
        // AVAssetImageGenerator. Debounce with a short sleep so rapid
        // zoom animations only trigger one final regen.
        .task(id: "\(videoURL.path)_\(duration)_\(Int(width / 32))") {
            try? await Task.sleep(nanoseconds: 140_000_000)
            if Task.isCancelled { return }
            await generateThumbnails()
        }
    }

    private func generateThumbnails() async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbWidth * 2, height: height * 2)

        let interval = duration / Double(thumbCount)
        var results: [(time: Double, image: NSImage)] = []

        for i in 0..<thumbCount {
            do {
                try Task.checkCancellation()
            } catch {
                return
            }
            let time = CMTime(seconds: interval * Double(i), preferredTimescale: 600)
            do {
                let (cgImage, _) = try await generator.image(at: time)
                let size = NSSize(width: cgImage.width, height: cgImage.height)
                let nsImage = NSImage(cgImage: cgImage, size: size)
                results.append((time: interval * Double(i), image: nsImage))
            } catch {
                if error is CancellationError { return }
                // Skip failed frames
            }
            await Task.yield()
        }

        if Task.isCancelled { return }
        await MainActor.run {
            self.thumbnails = results
        }
    }
}
