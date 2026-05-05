import AVFoundation
import Foundation
import CuttiKit

/// Analyzes audio quality by reading raw PCM samples from a video's audio
/// track. Detects silence, volume anomalies, and rough noise indicators.
///
/// # Known limitations (v0)
/// - **Static threshold**: `silenceThreshold` is an absolute RMS
///   value (default 0.01 ≈ -40 dBFS). Heavily-compressed podcasts with
///   an elevated noise floor will not register as "silent" even during
///   long pauses; conversely, a quiet whisper-tone track may be
///   classified as silence. A content-relative (percentile-based)
///   threshold is planned but out of scope for v0.
/// - **Coarse windowing**: a 0.5s sliding RMS window smooths over
///   fast plosives/clicks but also misses silences < 0.5s.
/// - **Serial scan**: the analyzer reads PCM sequentially on the
///   caller's thread. Multi-hour podcasts can take tens of seconds;
///   there is no cancellation hook yet.
///
/// These trade-offs are acceptable for the one-click "speed up silences"
/// pass the editor uses today; they are documented so consumers know
/// not to treat the output as a general-purpose VAD.
struct AudioQualityService: Sendable {

    /// RMS threshold below which a window is considered silent.
    /// Conservative default of 0.01 (~-40 dBFS) picks up typical
    /// well-produced podcast silences; raise it for noisy field
    /// recordings, lower it for extremely quiet speech.
    let silenceThreshold: Float

    /// Window size in seconds for RMS analysis.
    let windowSeconds: Double

    init(silenceThreshold: Float = 0.01, windowSeconds: Double = 0.5) {
        self.silenceThreshold = silenceThreshold
        self.windowSeconds = windowSeconds
    }

    // MARK: - Result

    struct Result: Sendable {
        let issues: [AICopilotIssue]
        let averageLoudnessDB: Double
        let silentRanges: [ClosedRange<Double>]
        let peakLoudnessDB: Double
        /// Per-window linear RMS values covering the full audio track,
        /// preserved for downstream consumers (hook scoring, energy
        /// visualisation). Older callers can ignore this field; new
        /// ones build an `AudioEnergyCurve` from `(values, windowSeconds)`.
        let windowRMSValues: [Float]
        /// Window size in seconds the RMS values were sampled at.
        /// Mirrors `AudioQualityService.windowSeconds`; surfaced so a
        /// consumer can build an `AudioEnergyCurve` without having to
        /// know how the analyser was configured.
        let windowSeconds: Double
    }

    // MARK: - Public

    func analyze(url: URL) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let audioTrack = audioTracks.first else {
            return Result(
                issues: [AICopilotIssue(
                    severity: .warning,
                    title: "No audio track",
                    detail: "This clip has no audio track."
                )],
                averageLoudnessDB: -.infinity,
                silentRanges: [],
                peakLoudnessDB: -.infinity,
                windowRMSValues: [],
                windowSeconds: windowSeconds
            )
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()

        // Collect all PCM samples
        var allSamples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { ptr in
                guard let baseAddress = ptr.baseAddress else { return }
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
            }
            let sampleCount = length / MemoryLayout<Int16>.size
            data.withUnsafeBytes { ptr in
                guard let bound = ptr.bindMemory(to: Int16.self).baseAddress else { return }
                allSamples.append(contentsOf: UnsafeBufferPointer(start: bound, count: sampleCount))
            }
        }

        guard !allSamples.isEmpty else {
            return Result(
                issues: [AICopilotIssue(severity: .warning, title: "Empty audio", detail: "Audio track contains no samples.")],
                averageLoudnessDB: -.infinity,
                silentRanges: [],
                peakLoudnessDB: -.infinity,
                windowRMSValues: [],
                windowSeconds: windowSeconds
            )
        }

        // Determine sample rate and channel count (default 44100 / 1)
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        let sampleRate: Double
        let channelCount: Int
        if let desc = formatDescriptions.first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
            sampleRate = asbd?.pointee.mSampleRate ?? 44100
            channelCount = max(1, Int(asbd?.pointee.mChannelsPerFrame ?? 1))
        } else {
            sampleRate = 44100
            channelCount = 1
        }

        // Convert interleaved samples to mono frames for analysis
        let monoSamples: [Int16]
        if channelCount > 1 {
            let frameCount = allSamples.count / channelCount
            monoSamples = (0..<frameCount).map { frame in
                let offset = frame * channelCount
                let sum = (0..<channelCount).reduce(Int32(0)) { acc, ch in
                    acc + Int32(allSamples[offset + ch])
                }
                return Int16(clamping: sum / Int32(channelCount))
            }
        } else {
            monoSamples = allSamples
        }

        let windowSize = Int(sampleRate * windowSeconds)
        return analyzeWindows(samples: monoSamples, windowSize: windowSize, sampleRate: sampleRate)
    }

    // MARK: - Private

    private func analyzeWindows(samples: [Int16], windowSize: Int, sampleRate: Double) -> Result {
        var windowRMSValues: [Float] = []
        var silentRanges: [ClosedRange<Double>] = []
        var silentStart: Double?
        let totalWindows = samples.count / windowSize

        for i in 0..<totalWindows {
            let start = i * windowSize
            let end = min(start + windowSize, samples.count)
            let window = samples[start..<end]

            let rms = Self.rms(of: window)
            windowRMSValues.append(rms)

            let timeStart = Double(start) / sampleRate
            let timeEnd = Double(end) / sampleRate

            if rms < silenceThreshold {
                if silentStart == nil { silentStart = timeStart }
            } else {
                if let s = silentStart {
                    silentRanges.append(s...timeStart)
                    silentStart = nil
                }
            }

            // Close trailing silence at the end
            if i == totalWindows - 1, let s = silentStart {
                silentRanges.append(s...timeEnd)
            }
        }

        guard !windowRMSValues.isEmpty else {
            return Result(
                issues: [],
                averageLoudnessDB: -.infinity,
                silentRanges: [],
                peakLoudnessDB: -.infinity,
                windowRMSValues: [],
                windowSeconds: windowSeconds
            )
        }

        let avgRMS = windowRMSValues.reduce(0, +) / Float(windowRMSValues.count)
        let peakRMS = windowRMSValues.max() ?? 0
        let avgDB = Self.toDecibels(avgRMS)
        let peakDB = Self.toDecibels(peakRMS)

        var issues: [AICopilotIssue] = []

        // Flag excessive silence (> 30% of total duration)
        let totalDuration = Double(samples.count) / sampleRate
        let silentDuration = silentRanges.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        if totalDuration > 0 && silentDuration / totalDuration > 0.3 {
            issues.append(AICopilotIssue(
                severity: .warning,
                title: "Excessive silence",
                detail: String(format: "%.0f%% of the clip is silent.", silentDuration / totalDuration * 100)
            ))
        }

        // Flag very low average volume
        if avgDB < -40 {
            issues.append(AICopilotIssue(
                severity: .warning,
                title: "Low audio volume",
                detail: String(format: "Average loudness is %.1f dB, which may be too quiet.", avgDB)
            ))
        }

        // Flag possible clipping
        if peakDB > -1 {
            issues.append(AICopilotIssue(
                severity: .info,
                title: "Possible audio clipping",
                detail: String(format: "Peak loudness is %.1f dB, close to digital maximum.", peakDB)
            ))
        }

        return Result(
            issues: issues,
            averageLoudnessDB: Double(avgDB),
            silentRanges: silentRanges,
            peakLoudnessDB: Double(peakDB),
            windowRMSValues: windowRMSValues,
            windowSeconds: windowSeconds
        )
    }

    private static func rms(of samples: ArraySlice<Int16>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { acc, sample in
            let normalized = Float(sample) / Float(Int16.max)
            return acc + normalized * normalized
        }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    private static func toDecibels(_ rms: Float) -> Double {
        guard rms > 0 else { return -.infinity }
        return Double(20 * log10(rms))
    }
}
