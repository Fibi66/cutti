import Foundation
import AVFoundation
import Vision
import CoreImage

/// Local-only vision analysis for iOS. Matches the macOS `vision.*`
/// presets so the iOS app doesn't have to round-trip video frames to
/// the cloud — `VNDetectFaceRectanglesRequest` and `CIAreaAverage` are
/// both hardware-accelerated on-device, so a few-minute clip finishes
/// in seconds and stays fully private.
///
/// Both entry points return a list of `[startSeconds, endSeconds]`
/// spans on the **source** media timeline (not the composed timeline).
/// Callers are expected to show these as a result list; applying them
/// as cuts is deferred so the user can review.
enum IOSVisionAnalyzer {

    struct Span: Sendable, Equatable {
        let startSeconds: Double
        let endSeconds: Double
        var durationSeconds: Double { endSeconds - startSeconds }
    }

    enum VisionError: Swift.Error, LocalizedError {
        case assetUnreadable
        case noVideoTrack

        var errorDescription: String? {
            switch self {
            case .assetUnreadable: return "无法读取视频"
            case .noVideoTrack:    return "这个文件没有可分析的视频轨"
            }
        }
    }

    // MARK: - Empty frames (no face visible)

    /// Samples `fps` frames per second and groups consecutive
    /// no-face samples into spans. `minSpanSeconds` filters out
    /// single-frame blips that would otherwise dominate the output.
    static func findEmptyFaceSpans(
        url: URL,
        samplesPerSecond fps: Double = 2.0,
        minSpanSeconds: Double = 0.6
    ) async throws -> [Span] {
        try await sampleAndCollect(
            url: url,
            samplesPerSecond: fps,
            minSpanSeconds: minSpanSeconds,
            predicate: { cgImage in
                let request = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let faces = request.results ?? []
                // "Empty" = no face visible
                return faces.isEmpty
            }
        )
    }

    // MARK: - Black frames

    /// Samples frames and flags those with an average luminance
    /// below `threshold` (0…1). 0.06 catches fully-black, covered
    /// lens, and extreme underexposure without tagging every low-key
    /// night shot.
    static func findBlackSpans(
        url: URL,
        samplesPerSecond fps: Double = 2.0,
        minSpanSeconds: Double = 0.4,
        threshold: Double = 0.06
    ) async throws -> [Span] {
        let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
        return try await sampleAndCollect(
            url: url,
            samplesPerSecond: fps,
            minSpanSeconds: minSpanSeconds,
            predicate: { cgImage in
                let ci = CIImage(cgImage: cgImage)
                let extent = ci.extent
                guard let filter = CIFilter(name: "CIAreaAverage") else { return false }
                filter.setValue(ci, forKey: kCIInputImageKey)
                filter.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
                guard let output = filter.outputImage else { return false }
                var pixel = [UInt8](repeating: 0, count: 4)
                ciContext.render(
                    output,
                    toBitmap: &pixel,
                    rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8,
                    colorSpace: nil
                )
                // Rec. 709 luma from the single averaged pixel.
                let r = Double(pixel[0]) / 255.0
                let g = Double(pixel[1]) / 255.0
                let b = Double(pixel[2]) / 255.0
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                return luma < threshold
            }
        )
    }

    // MARK: - Shared sampler

    /// Walk the asset at `samplesPerSecond`, run `predicate` on each
    /// decoded frame, and collapse runs of `true` samples into spans.
    private static func sampleAndCollect(
        url: URL,
        samplesPerSecond fps: Double,
        minSpanSeconds: Double,
        predicate: @escaping @Sendable (CGImage) -> Bool
    ) async throws -> [Span] {
        let asset = AVURLAsset(url: url)
        guard let _ = try? await asset.load(.tracks).first(where: { $0.mediaType == .video })
        else { throw VisionError.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw VisionError.assetUnreadable }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 480, height: 480)

        let step = max(0.1, 1.0 / fps)
        var t: Double = 0
        // (time, matched) pairs — we compute spans from the run pattern.
        var samples: [(Double, Bool)] = []

        while t < duration {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                samples.append((t, predicate(cg)))
            } else {
                samples.append((t, false))
            }
            t += step
        }

        return collapseRuns(samples: samples, step: step, minSpanSeconds: minSpanSeconds, duration: duration)
    }

    private static func collapseRuns(
        samples: [(Double, Bool)],
        step: Double,
        minSpanSeconds: Double,
        duration: Double
    ) -> [Span] {
        var spans: [Span] = []
        var runStart: Double? = nil
        for (time, hit) in samples {
            if hit && runStart == nil {
                runStart = time
            } else if !hit, let s = runStart {
                let e = min(duration, time)
                if e - s >= minSpanSeconds {
                    spans.append(Span(startSeconds: s, endSeconds: e))
                }
                runStart = nil
            }
        }
        if let s = runStart {
            let e = duration
            if e - s >= minSpanSeconds {
                spans.append(Span(startSeconds: s, endSeconds: e))
            }
        }
        return spans
    }
}
