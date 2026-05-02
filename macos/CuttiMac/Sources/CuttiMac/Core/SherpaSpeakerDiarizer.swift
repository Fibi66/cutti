import Foundation
import SherpaOnnxC

/// Minimal Swift wrappers around the sherpa-onnx C API, carved out of
/// upstream's `swift-api-examples/SherpaOnnx.swift` to only include the
/// speaker-diarization surface we use. All wrappers manage their own C
/// memory via `deinit` to prevent leaks.

@inline(__always)
private func toCPointer(_ s: String) -> UnsafePointer<Int8>! {
    UnsafePointer<Int8>((s as NSString).utf8String)
}

enum SherpaDiarization {

    static func pyannoteModelConfig(model: String)
    -> SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig {
        SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: toCPointer(model))
    }

    static func segmentationModelConfig(
        pyannote: SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig,
        numThreads: Int = 2,
        debug: Int = 0,
        provider: String = "cpu"
    ) -> SherpaOnnxOfflineSpeakerSegmentationModelConfig {
        SherpaOnnxOfflineSpeakerSegmentationModelConfig(
            pyannote: pyannote,
            num_threads: Int32(numThreads),
            debug: Int32(debug),
            provider: toCPointer(provider)
        )
    }

    static func fastClusteringConfig(numClusters: Int = -1, threshold: Float = 0.5)
    -> SherpaOnnxFastClusteringConfig {
        SherpaOnnxFastClusteringConfig(
            num_clusters: Int32(numClusters),
            threshold: threshold
        )
    }

    static func embeddingExtractorConfig(
        model: String,
        numThreads: Int = 2,
        debug: Int = 0,
        provider: String = "cpu"
    ) -> SherpaOnnxSpeakerEmbeddingExtractorConfig {
        SherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: toCPointer(model),
            num_threads: Int32(numThreads),
            debug: Int32(debug),
            provider: toCPointer(provider)
        )
    }

    static func diarizationConfig(
        segmentation: SherpaOnnxOfflineSpeakerSegmentationModelConfig,
        embedding: SherpaOnnxSpeakerEmbeddingExtractorConfig,
        clustering: SherpaOnnxFastClusteringConfig,
        minDurationOn: Float = 0.3,
        minDurationOff: Float = 0.5
    ) -> SherpaOnnxOfflineSpeakerDiarizationConfig {
        SherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: segmentation,
            embedding: embedding,
            clustering: clustering,
            min_duration_on: minDurationOn,
            min_duration_off: minDurationOff
        )
    }
}

/// Concrete diarization result row: [start, end) seconds of clean audio
/// assigned to speaker index `speaker`.
struct SherpaSpeakerSegment {
    let start: Double
    let end: Double
    let speaker: Int
}

/// Thin, thread-safe wrapper around `SherpaOnnxOfflineSpeakerDiarization`.
/// Holds model handles for the lifetime of the object; create once per
/// analysis batch, not per video.
final class SherpaSpeakerDiarizer {
    private var impl: OpaquePointer?
    let requiredSampleRate: Int

    /// - Parameters:
    ///   - segmentationModelPath: local path to `segmentation.onnx`
    ///     (pyannote-segmentation-3-0).
    ///   - embeddingModelPath: local path to the 3D-Speaker or NeMo
    ///     embedding `.onnx`.
    ///   - clusteringThreshold: cosine distance threshold used by the
    ///     fast clustering when the speaker count is unknown. Lower
    ///     values split more aggressively; the sherpa-onnx default is
    ///     `0.5`.
    init(
        segmentationModelPath: String,
        embeddingModelPath: String,
        clusteringThreshold: Float = 0.5,
        numThreads: Int = 2
    ) throws {
        var config = SherpaDiarization.diarizationConfig(
            segmentation: SherpaDiarization.segmentationModelConfig(
                pyannote: SherpaDiarization.pyannoteModelConfig(model: segmentationModelPath),
                numThreads: numThreads
            ),
            embedding: SherpaDiarization.embeddingExtractorConfig(
                model: embeddingModelPath,
                numThreads: numThreads
            ),
            // numClusters = -1 → sherpa-onnx decides the speaker count
            // via threshold-based fast clustering.
            clustering: SherpaDiarization.fastClusteringConfig(
                numClusters: -1,
                threshold: clusteringThreshold
            )
        )

        let handle = withUnsafePointer(to: &config) { ptr in
            SherpaOnnxCreateOfflineSpeakerDiarization(ptr)
        }
        guard let handle else {
            throw SherpaSpeakerDiarizerError.createFailed
        }
        self.impl = handle
        self.requiredSampleRate = Int(
            SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(handle)
        )
    }

    deinit {
        if let impl {
            SherpaOnnxDestroyOfflineSpeakerDiarization(impl)
        }
    }

    /// Run diarization over a full-file PCM buffer. `samples` must be
    /// mono float32 in `[-1, 1]` at `requiredSampleRate` (typically
    /// 16 kHz). Returns segments sorted by start time.
    func process(samples: [Float]) throws -> [SherpaSpeakerSegment] {
        guard let impl else { throw SherpaSpeakerDiarizerError.notInitialized }
        guard !samples.isEmpty else { return [] }

        guard let raw = samples.withUnsafeBufferPointer({ buf -> OpaquePointer? in
            SherpaOnnxOfflineSpeakerDiarizationProcess(
                impl,
                buf.baseAddress,
                Int32(buf.count)
            )
        }) else {
            return []
        }

        let n = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(raw))
        guard n > 0 else {
            SherpaOnnxOfflineSpeakerDiarizationDestroyResult(raw)
            return []
        }

        guard let sortedPtr: UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationSegment> =
            SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(raw) else {
            SherpaOnnxOfflineSpeakerDiarizationDestroyResult(raw)
            return []
        }

        var out: [SherpaSpeakerSegment] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let seg = sortedPtr[i]
            out.append(SherpaSpeakerSegment(
                start: Double(seg.start),
                end: Double(seg.end),
                speaker: Int(seg.speaker)
            ))
        }

        SherpaOnnxOfflineSpeakerDiarizationDestroySegment(sortedPtr)
        SherpaOnnxOfflineSpeakerDiarizationDestroyResult(raw)

        return out
    }
}

enum SherpaSpeakerDiarizerError: Error, LocalizedError {
    case createFailed
    case notInitialized

    var errorDescription: String? {
        switch self {
        case .createFailed:
            return "Failed to initialize sherpa-onnx speaker diarizer. Check that the model files are present."
        case .notInitialized:
            return "Speaker diarizer is not initialized."
        }
    }
}
