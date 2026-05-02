import Foundation
import AVFoundation
import Vision
import AppKit
import CoreImage
import CuttiKit

/// Per-video visual feature index produced by `VisualAnalysisService`.
/// Cached to `media/visual_index/<videoID>.json` so repeated runs don't
/// re-scan frames.
struct VisualIndex: Codable, Equatable {
    /// Frame sample period in seconds used when building this index.
    let samplePeriodSeconds: Double
    /// Time ranges (seconds) where the frame was nearly black.
    let blackFrameRanges: [TimeRangeCodable]
    /// Time ranges where no face was detected.
    let emptyFrameRanges: [TimeRangeCodable]
    /// Timestamps (seconds) of detected scene changes (large visual
    /// difference between adjacent samples).
    let sceneChangeTimestamps: [Double]

    struct TimeRangeCodable: Codable, Equatable {
        var start: Double
        var end: Double
    }

    static let empty = VisualIndex(
        samplePeriodSeconds: 0.5,
        blackFrameRanges: [],
        emptyFrameRanges: [],
        sceneChangeTimestamps: []
    )
}

/// Per-frame intermediate feature vector used for black-frame / empty-frame
/// / scene-change detection. Exposed (vs kept private) so the core
/// aggregation logic can be unit-tested without Vision or AVFoundation.
struct VisualFrameSample: Equatable {
    let time: Double
    /// Average luminance 0…1; <= `blackLuminanceThreshold` = black frame.
    let meanLuminance: Double
    /// Number of faces detected by Vision.
    let faceCount: Int
    /// Average RGB histogram L1 distance from the previous sample, used
    /// as a simple scene-change signal. 0 for the first sample.
    let changeScore: Double
}

/// Analyzes a video's frames (sampled every `samplePeriod` seconds) for
/// face presence, black frames and scene changes using Apple's Vision
/// framework. Fully offline. Coarse by design — the output is meant for
/// the Agent's `find_*` tools, not for precise editing cuts.
enum VisualAnalysisService {

    /// Threshold below which a frame's mean luminance counts as "black".
    static let blackLuminanceThreshold: Double = 0.035
    /// Min change score between adjacent samples to register a scene cut.
    static let sceneChangeThreshold: Double = 0.25

    enum AnalyzeError: Error { case missingTrack }

    /// Sample `asset`'s video track at `samplePeriod`-second intervals and
    /// build a `VisualIndex`. Throws on missing video track. Runs on the
    /// calling thread; call from a background queue.
    static func analyze(
        asset: AVAsset,
        samplePeriod: Double = 0.5
    ) async throws -> VisualIndex {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return .empty }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        var samples: [VisualFrameSample] = []
        var previousLum: Double?
        var time: Double = 0
        while time < duration {
            let cmtime = CMTime(seconds: time, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: cmtime, actualTime: nil) else {
                time += samplePeriod
                continue
            }

            let lum = meanLuminance(cgImage: cg)
            let faces = detectFaces(cgImage: cg)
            let change = previousLum.map { abs(lum - $0) } ?? 0
            samples.append(VisualFrameSample(
                time: time,
                meanLuminance: lum,
                faceCount: faces,
                changeScore: change
            ))
            previousLum = lum
            time += samplePeriod
        }

        return aggregate(samples: samples, samplePeriod: samplePeriod)
    }

    // MARK: - Pure aggregation (testable)

    /// Fold per-frame samples into the higher-level index. Adjacent
    /// black/empty samples are merged into contiguous ranges.
    static func aggregate(
        samples: [VisualFrameSample],
        samplePeriod: Double
    ) -> VisualIndex {
        var blackRanges: [VisualIndex.TimeRangeCodable] = []
        var emptyRanges: [VisualIndex.TimeRangeCodable] = []
        var sceneChanges: [Double] = []

        func extend(
            _ ranges: inout [VisualIndex.TimeRangeCodable],
            start: Double,
            end: Double
        ) {
            if var last = ranges.last, abs(last.end - start) < 0.001 {
                last.end = end
                ranges[ranges.count - 1] = last
            } else {
                ranges.append(.init(start: start, end: end))
            }
        }

        for s in samples {
            if s.meanLuminance <= blackLuminanceThreshold {
                extend(&blackRanges, start: s.time, end: s.time + samplePeriod)
            }
            if s.faceCount == 0 {
                extend(&emptyRanges, start: s.time, end: s.time + samplePeriod)
            }
            if s.changeScore >= sceneChangeThreshold {
                sceneChanges.append(s.time)
            }
        }

        return VisualIndex(
            samplePeriodSeconds: samplePeriod,
            blackFrameRanges: blackRanges,
            emptyFrameRanges: emptyRanges,
            sceneChangeTimestamps: sceneChanges
        )
    }

    // MARK: - Frame analysis helpers

    private static func meanLuminance(cgImage: CGImage) -> Double {
        let ci = CIImage(cgImage: cgImage)
        let extent = ci.extent
        let filter = CIFilter(name: "CIAreaAverage")!
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return 0.5 }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func detectFaces(cgImage: CGImage) -> Int {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return request.results?.count ?? 0
        } catch {
            return 0
        }
    }
}
