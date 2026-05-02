import AVFoundation
import CoreImage
import Foundation
import Vision
import CuttiKit

/// Decision + geometry for the Auto-PiP one-click command.
///
/// The analyzer does two independent jobs:
///
///  1. **Presenter detection** — sample N frames of the overlay (V2)
///     source video window and decide whether this clip looks like a
///     talking head. Criteria are intentionally conservative so we never
///     suggest PiP on clips that aren't presenter-cams (a bad auto
///     suggestion erodes user trust faster than a missed one).
///
///  2. **Corner selection** — sample N frames of the primary (V1)
///     source window, split each into a 2×2 grid, score each quadrant
///     by content "density" (face bbox area + attention saliency mean),
///     aggregate across samples, and pick the quadrant that is LEAST
///     busy so the PiP thumbnail doesn't cover important content.
///
/// Both jobs share the same Vision framework the rest of the app uses
/// (`VNDetectFaceRectanglesRequest`, `VNGenerateAttentionBasedSaliency`)
/// — no new models / frameworks introduced.
///
/// All pure-math helpers (aggregation, decision thresholds, tie-break)
/// are exposed as `static` so they can be unit-tested without ever
/// touching AVFoundation or Vision.
enum AutoPiPAnalyzer {

    // MARK: - Public result types

    /// Decision payload: whether the overlay looks like a presenter cam
    /// + which corner on V1 is the least busy + a ready-to-write layout.
    struct Decision: Equatable {
        /// True if the overlay passed the presenter-cam heuristic.
        let isPresenterCam: Bool
        /// Confidence in `[0, 1]` — face-hit-rate × face-size-factor ×
        /// quadrant-stability.
        let confidence: Double
        /// Median face height as a fraction of frame height. 0 if no
        /// faces were detected.
        let medianFaceHeightFraction: Double
        /// Lowest-density corner on V1; always populated (we fall back
        /// to `bottomRight` if all scores tie).
        let bestCorner: PiPLayout.Corner
        /// Per-corner density score in `[0, +∞)` — higher = busier.
        /// Useful for test assertions.
        let densityByCorner: [PiPLayout.Corner: Double]
        /// Suggested layout to write onto the overlay segment when
        /// the user accepts. Nil when the clip is not a presenter cam.
        let suggestedLayout: PiPLayout?
    }

    /// Face observation boiled down to the minimum the decision logic
    /// needs. Parallel type exists so tests don't depend on Vision.
    struct FaceSample: Equatable {
        /// Bounding box in normalized Vision coordinates (origin
        /// bottom-left, width/height in `[0, 1]`).
        let bbox: CGRect
    }

    /// Per-frame sample of V2, used by `decidePresenter`.
    struct PresenterFrameSample: Equatable {
        let faces: [FaceSample]
    }

    /// Per-frame sample of V1, used by `decideCorner`. `textArea` and
    /// `saliencyMean` are indexed by corner; values in `[0, 1]`.
    struct DensityFrameSample: Equatable {
        let perCorner: [PiPLayout.Corner: Double]
    }

    // MARK: - Presenter decision (pure)

    /// Heuristic thresholds. Exposed so tests can reason about the
    /// decision surface without re-declaring magic numbers.
    static let minFaceHitRate: Double = 0.6
    static let minMedianFaceHeightFraction: Double = 0.15
    static let quadrantStabilityThreshold: Double = 0.6 // % samples in same quadrant

    /// Given a set of per-frame presenter samples, decide whether the
    /// clip qualifies as a presenter cam.
    ///
    /// Returns:
    ///   - `isPresenterCam`: all three criteria met
    ///   - `confidence`: geometric mean of the three normalized signals
    ///   - `medianFaceHeightFraction`: median of largest-face heights
    static func decidePresenter(samples: [PresenterFrameSample]) -> (isPresenterCam: Bool, confidence: Double, medianFaceHeightFraction: Double) {
        guard !samples.isEmpty else { return (false, 0, 0) }

        let framesWithFace = samples.filter { !$0.faces.isEmpty }
        let faceHitRate = Double(framesWithFace.count) / Double(samples.count)

        // Use the LARGEST face per frame — if two people are in-shot,
        // the one in front is the presenter.
        let largestHeights: [Double] = framesWithFace.compactMap { sample in
            sample.faces.map { Double($0.bbox.height) }.max()
        }
        let medianFaceHeight = median(largestHeights)

        // Quadrant stability: bucket the largest face's center into one
        // of the 4 quadrants per frame, then pick the majority quadrant.
        var quadrantCounts: [PiPLayout.Corner: Int] = [:]
        for sample in framesWithFace {
            guard let biggest = sample.faces.max(by: { $0.bbox.height < $1.bbox.height }) else { continue }
            let q = quadrant(forNormalizedPoint: CGPoint(x: biggest.bbox.midX, y: biggest.bbox.midY))
            quadrantCounts[q, default: 0] += 1
        }
        let maxQuadrantCount = quadrantCounts.values.max() ?? 0
        let stability = framesWithFace.isEmpty ? 0 : Double(maxQuadrantCount) / Double(framesWithFace.count)

        let passes = faceHitRate >= minFaceHitRate
            && medianFaceHeight >= minMedianFaceHeightFraction
            && stability >= quadrantStabilityThreshold

        // Normalize each signal to `[0, 1]` then take the geometric mean
        // so a very weak single signal can still veto a high combined
        // score. Clipped to 1 on the upper end.
        let nHit = min(1.0, faceHitRate / 1.0)
        let nHeight = min(1.0, medianFaceHeight / 0.40) // saturates at 40% — big talking head
        let nStab = min(1.0, stability / 1.0)
        let confidence = pow(nHit * nHeight * nStab, 1.0 / 3.0)

        return (passes, confidence, medianFaceHeight)
    }

    // MARK: - Corner decision (pure)

    /// Tie-break tolerance: when the best corner's score is within this
    /// fraction of another corner's score, prefer `bottomRight`. Picked
    /// empirically — anything larger starts to look "random" to users.
    static let cornerTieBreakTolerance: Double = 0.10

    /// Pick the lowest-density corner from per-frame samples. Ties
    /// within `cornerTieBreakTolerance` break to `bottomRight`.
    static func decideCorner(
        samples: [DensityFrameSample]
    ) -> (bestCorner: PiPLayout.Corner, totals: [PiPLayout.Corner: Double]) {
        var totals: [PiPLayout.Corner: Double] = [
            .topLeft: 0, .topRight: 0, .bottomLeft: 0, .bottomRight: 0
        ]
        for s in samples {
            for corner in PiPLayout.Corner.allCases {
                totals[corner, default: 0] += s.perCorner[corner] ?? 0
            }
        }
        guard let minScore = totals.values.min() else {
            return (.bottomRight, totals)
        }
        // Candidates: any corner within tolerance of the minimum.
        let toleranceBand = minScore + abs(minScore) * cornerTieBreakTolerance + 0.0001
        let candidates = PiPLayout.Corner.allCases.filter { (totals[$0] ?? 0) <= toleranceBand }
        if candidates.contains(.bottomRight) { return (.bottomRight, totals) }
        // Stable order: bottomRight, bottomLeft, topRight, topLeft.
        let order: [PiPLayout.Corner] = [.bottomRight, .bottomLeft, .topRight, .topLeft]
        let pick = order.first { candidates.contains($0) } ?? .bottomRight
        return (pick, totals)
    }

    // MARK: - Shape decision (pure)

    /// Pick a PiP shape based on the source aspect ratio. Near-square
    /// sources get a circle for a familiar webcam look; wide sources
    /// become rounded squares so we don't crop too aggressively.
    static func decideShape(sourceAspect: Double) -> PiPLayout.Shape {
        guard sourceAspect.isFinite, sourceAspect > 0 else { return .roundedSquare }
        let delta = abs(sourceAspect - 1.0)
        return delta <= 0.15 ? .circle : .roundedSquare
    }

    // MARK: - Helpers

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Bucket a normalized point (origin bottom-left, `[0,1]×[0,1]`)
    /// into the matching PiP corner. Used by presenter-quadrant
    /// stability AND by density aggregation so both stay in sync.
    static func quadrant(forNormalizedPoint p: CGPoint) -> PiPLayout.Corner {
        let left = p.x < 0.5
        let bottom = p.y < 0.5
        switch (left, bottom) {
        case (true, false): return .topLeft
        case (false, false): return .topRight
        case (true, true): return .bottomLeft
        case (false, true): return .bottomRight
        }
    }

    // MARK: - Vision-backed runner (impure)

    /// Sample the overlay video at `sampleCount` evenly-spaced frames
    /// within `[rangeStart, rangeEnd]`, detect faces via Vision, and
    /// return the presenter samples. Any frame that fails to decode or
    /// fails Vision is dropped — sample loss is preferable to throwing
    /// because the user's click shouldn't fail on a single bad frame.
    static func samplePresenterFrames(
        asset: AVAsset,
        rangeStart: Double,
        rangeEnd: Double,
        sampleCount: Int = 5
    ) async -> [PresenterFrameSample] {
        guard rangeEnd > rangeStart, sampleCount > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        var samples: [PresenterFrameSample] = []
        for i in 0..<sampleCount {
            let t = sampleCount == 1
                ? (rangeStart + rangeEnd) / 2
                : rangeStart + Double(i) * (rangeEnd - rangeStart) / Double(sampleCount - 1)
            let cmtime = CMTime(seconds: t, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: cmtime, actualTime: nil) else { continue }
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continue
            }
            let faces = (request.results ?? []).map { FaceSample(bbox: $0.boundingBox) }
            samples.append(PresenterFrameSample(faces: faces))
        }
        return samples
    }

    /// Sample V1 frames and score each quadrant's density using
    /// `VNGenerateAttentionBasedSaliencyImageRequest`. Saliency is a
    /// 68×68 (typically) heatmap in the `pixelBuffer`; we resample into
    /// a 2×2 grid by averaging each quadrant.
    static func sampleDensityFrames(
        asset: AVAsset,
        rangeStart: Double,
        rangeEnd: Double,
        sampleCount: Int = 5
    ) async -> [DensityFrameSample] {
        guard rangeEnd > rangeStart, sampleCount > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        var samples: [DensityFrameSample] = []
        for i in 0..<sampleCount {
            let t = sampleCount == 1
                ? (rangeStart + rangeEnd) / 2
                : rangeStart + Double(i) * (rangeEnd - rangeStart) / Double(sampleCount - 1)
            let cmtime = CMTime(seconds: t, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: cmtime, actualTime: nil) else { continue }

            var perCorner: [PiPLayout.Corner: Double] = [
                .topLeft: 0, .topRight: 0, .bottomLeft: 0, .bottomRight: 0
            ]

            // Face contribution: bbox area per quadrant.
            let faceReq = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            _ = try? handler.perform([faceReq])
            for obs in (faceReq.results ?? []) {
                // Allocate the face bbox's area into quadrants by its
                // center. A face straddling the midline will count
                // toward whichever side its center falls on — good
                // enough for a corner pick.
                let center = CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY)
                let area = Double(obs.boundingBox.width * obs.boundingBox.height)
                perCorner[quadrant(forNormalizedPoint: center), default: 0] += area
            }

            // Saliency contribution: per-quadrant mean of the heatmap.
            let salReq = VNGenerateAttentionBasedSaliencyImageRequest()
            _ = try? handler.perform([salReq])
            if let sal = (salReq.results?.first as? VNSaliencyImageObservation),
               let quadMeans = saliencyQuadrantMeans(from: sal.pixelBuffer) {
                for (k, v) in quadMeans {
                    perCorner[k, default: 0] += v
                }
            }

            samples.append(DensityFrameSample(perCorner: perCorner))
        }
        return samples
    }

    /// Compute mean intensity per 2×2 quadrant on a saliency pixel
    /// buffer. Saliency buffers are single-channel 32-bit float. Values
    /// are already in `[0, 1]`.
    static func saliencyQuadrantMeans(from buffer: CVPixelBuffer) -> [PiPLayout.Corner: Double]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 1, height > 1,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        var sums: [PiPLayout.Corner: Double] = [
            .topLeft: 0, .topRight: 0, .bottomLeft: 0, .bottomRight: 0
        ]
        var counts: [PiPLayout.Corner: Int] = [
            .topLeft: 0, .topRight: 0, .bottomLeft: 0, .bottomRight: 0
        ]

        // Saliency buffer uses top-left origin (CoreVideo) but Vision
        // normalized bboxes are bottom-left. Flip Y here to keep the
        // saliency map in the same quadrant space as the face code.
        let rowStride = bytesPerRow / MemoryLayout<Float>.size
        let ptr = base.assumingMemoryBound(to: Float.self)
        let halfX = width / 2
        let halfY = height / 2
        for y in 0..<height {
            let bottom = y >= halfY // top-left origin → lower half of buffer
            let normalizedBottom = !bottom // flipped back to bottom-left origin
            for x in 0..<width {
                let left = x < halfX
                let q = normalizedBottom
                    ? (left ? PiPLayout.Corner.bottomLeft : .bottomRight)
                    : (left ? PiPLayout.Corner.topLeft : .topRight)
                sums[q, default: 0] += Double(ptr[y * rowStride + x])
                counts[q, default: 0] += 1
            }
        }
        var out: [PiPLayout.Corner: Double] = [:]
        for k in PiPLayout.Corner.allCases {
            let c = counts[k] ?? 0
            out[k] = c > 0 ? (sums[k] ?? 0) / Double(c) : 0
        }
        return out
    }

    // MARK: - Orchestration

    /// End-to-end: classify the overlay + pick a corner on V1, then
    /// return a `Decision` ready to hand to the UI or VM.
    ///
    /// Both sources are `AVAsset` so this can be called from tests with
    /// composed test fixtures, not just the app's proxy URLs.
    static func analyze(
        primaryAsset: AVAsset,
        primaryRangeStart: Double,
        primaryRangeEnd: Double,
        overlayAsset: AVAsset,
        overlayRangeStart: Double,
        overlayRangeEnd: Double,
        overlaySourceAspect: Double,
        sampleCount: Int = 5
    ) async -> Decision {
        let presenterSamples = await samplePresenterFrames(
            asset: overlayAsset,
            rangeStart: overlayRangeStart,
            rangeEnd: overlayRangeEnd,
            sampleCount: sampleCount
        )
        let (isPresenter, confidence, medianFaceHeight) = decidePresenter(samples: presenterSamples)

        let densitySamples = await sampleDensityFrames(
            asset: primaryAsset,
            rangeStart: primaryRangeStart,
            rangeEnd: primaryRangeEnd,
            sampleCount: sampleCount
        )
        let (corner, totals) = decideCorner(samples: densitySamples)

        var layout: PiPLayout? = nil
        if isPresenter {
            var l = PiPLayout.default
            l.corner = corner
            l.shape = decideShape(sourceAspect: overlaySourceAspect)
            l.sizeFraction = 0.22
            l.insetFraction = 0.025
            layout = l.normalized()
        }

        return Decision(
            isPresenterCam: isPresenter,
            confidence: confidence,
            medianFaceHeightFraction: medianFaceHeight,
            bestCorner: corner,
            densityByCorner: totals,
            suggestedLayout: layout
        )
    }
}
