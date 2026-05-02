import Foundation
import CuttiKit

/// Pure helpers for one-click audio post: loudness normalization and silence
/// compression. The functions in here are deliberately side-effect free so
/// they can be unit-tested without touching AVFoundation. The concrete
/// MediaCoreViewModel applies the resulting actions via the regular
/// AIAction pipeline (so undo/redo Just Works).
enum AudioPostProcessor {

    // MARK: - Loudness normalization

    /// Compute per-source linear gain (multiplier on top of an existing 0…1
    /// volume) needed to move that source toward `targetDB`. Because
    /// `AVMutableAudioMix.setVolume` doesn't permit values > 1.0, the
    /// returned multiplier is clamped at 1.0 — i.e. we attenuate loud
    /// sources and leave quiet sources alone.
    /// - Parameters:
    ///   - sourceAverageDB: source-id → measured average loudness in dBFS
    ///   - targetDB: desired loudness, e.g. -16 dBFS for a podcast feel
    /// - Returns: source-id → linear gain in [0, 1]; missing entries imply
    ///   no gain change should be applied.
    static func computeNormalizationGains(
        sourceAverageDB: [UUID: Double],
        targetDB: Double
    ) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for (id, avgDB) in sourceAverageDB {
            // Silent / undetectable input: skip.
            guard avgDB.isFinite, avgDB > -120 else { continue }
            let deltaDB = targetDB - avgDB
            // Only attenuate; don't try to boost beyond unity gain.
            guard deltaDB < 0 else { continue }
            let gain = pow(10.0, deltaDB / 20.0)
            out[id] = max(0.0, min(1.0, gain))
        }
        return out
    }

    // MARK: - Silence compression

    /// A speed-up region produced by silence compression, expressed in the
    /// composed timeline (the same coordinate space `AIAction.setSpeedRange`
    /// expects).
    struct SpeedUpRegion: Equatable {
        let startSeconds: Double
        let endSeconds: Double
        let rate: Double
    }

    /// Translate per-source silent ranges into composed-time speed-up
    /// regions. Only silences strictly inside a segment (and at least
    /// `minDuration` long) are emitted; silences that cross a segment cut
    /// are clipped to the in-segment portion. Coordinates already account
    /// for any prior speed changes on each segment so they're directly
    /// usable as `setSpeedRange(start, end, rate)`.
    static func computeSilenceSpeedUps(
        segments: [TimelineSegment],
        silentRangesBySource: [UUID: [ClosedRange<Double>]],
        minDuration: Double,
        rate: Double
    ) -> [SpeedUpRegion] {
        guard minDuration > 0, rate > 1.0 else { return [] }

        var out: [SpeedUpRegion] = []
        var composedOffset: Double = 0

        for seg in segments {
            let segStart = seg.range.startSeconds
            let segEnd = seg.range.endSeconds
            let speed = seg.normalizedSpeedRate
            let segComposedDuration = (segEnd - segStart) / speed

            if let silences = silentRangesBySource[seg.sourceVideoID] {
                for range in silences {
                    // Clip to the source-time portion that falls inside
                    // this segment.
                    let lo = max(range.lowerBound, segStart)
                    let hi = min(range.upperBound, segEnd)
                    let sourceDuration = hi - lo
                    if sourceDuration < minDuration { continue }
                    // Project source-time → composed-time.
                    let composedLo = composedOffset + (lo - segStart) / speed
                    let composedHi = composedOffset + (hi - segStart) / speed
                    out.append(SpeedUpRegion(
                        startSeconds: composedLo,
                        endSeconds: composedHi,
                        rate: rate
                    ))
                }
            }
            composedOffset += segComposedDuration
        }

        return out
    }
}
