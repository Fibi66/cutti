import AVFoundation
import CoreImage
import Foundation
import Vision
import CuttiKit

/// Analyzes video frames using the Vision framework to extract semantic tags,
/// detect faces (talking-head detection), and identify scene boundaries.
///
/// Samples frames at a configurable interval and runs `VNClassifyImageRequest`
/// and `VNDetectFaceRectanglesRequest` on each sample.
struct SceneAnalysisService: Sendable {

    /// Interval in seconds between sampled frames.
    let sampleInterval: Double

    init(sampleInterval: Double = 2.0) {
        self.sampleInterval = sampleInterval
    }

    // MARK: - Result

    struct Result: Sendable {
        let semanticTags: [String]
        let sceneBoundaries: [SceneBoundary]
        let hasTalkingHead: Bool
        /// Fraction of sampled frames that contain at least one face.
        let facePresenceRatio: Double
    }

    // MARK: - Public

    func analyze(url: URL, durationSeconds: Double) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        // Scale down for faster classification
        generator.maximumSize = CGSize(width: 640, height: 360)

        let sampleCount = max(1, Int(durationSeconds / sampleInterval))
        let times = (0..<sampleCount).map { i in
            CMTime(seconds: Double(i) * sampleInterval, preferredTimescale: 600)
        }

        var allLabels: [[String: Double]] = []
        var faceFrameCount = 0
        var prevTopLabel: String?
        var boundaries: [SceneBoundary] = []

        for time in times {
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                continue
            }

            let frameLabels = try await classifyImage(cgImage)
            let hasFace = try await detectFaces(cgImage)

            allLabels.append(frameLabels)
            if hasFace { faceFrameCount += 1 }

            // Detect scene boundaries via top label change
            let topLabel = frameLabels.max(by: { $0.value < $1.value })?.key
            if let top = topLabel, top != prevTopLabel, prevTopLabel != nil {
                boundaries.append(SceneBoundary(
                    seconds: CMTimeGetSeconds(time),
                    label: top
                ))
            }
            prevTopLabel = topLabel
        }

        let semanticTags = aggregateTopTags(from: allLabels, maxCount: 5)
        let faceRatio = sampleCount > 0 ? Double(faceFrameCount) / Double(sampleCount) : 0
        let hasTalkingHead = faceRatio > 0.5

        return Result(
            semanticTags: semanticTags,
            sceneBoundaries: boundaries,
            hasTalkingHead: hasTalkingHead,
            facePresenceRatio: faceRatio
        )
    }

    // MARK: - Vision requests

    private func classifyImage(_ cgImage: CGImage) async throws -> [String: Double] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var labels: [String: Double] = [:]
                if let observations = request.results as? [VNClassificationObservation] {
                    for obs in observations where obs.confidence > 0.3 {
                        labels[obs.identifier] = Double(obs.confidence)
                    }
                }
                continuation.resume(returning: labels)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func detectFaces(_ cgImage: CGImage) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let faces = (request.results as? [VNFaceObservation]) ?? []
                continuation.resume(returning: !faces.isEmpty)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Aggregation

    /// Aggregates labels across all frames, picking the highest-confidence tags.
    private func aggregateTopTags(from allLabels: [[String: Double]], maxCount: Int) -> [String] {
        var aggregated: [String: Double] = [:]
        for frameLabels in allLabels {
            for (label, confidence) in frameLabels {
                aggregated[label, default: 0] += confidence
            }
        }
        return aggregated
            .sorted { $0.value > $1.value }
            .prefix(maxCount)
            .map(\.key)
    }
}
