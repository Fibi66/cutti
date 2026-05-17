import AVFoundation
import Foundation

/// Extracts 16 kHz mono float32 PCM from a video/audio file and runs it
/// through the sherpa-onnx diarizer, returning speaker-labelled time
/// ranges in **source time** (seconds from the start of the input file).
///
/// Callers are responsible for mapping those ranges onto composed-time
/// subtitles. See `MediaCoreViewModel.autoDetectSpeakersReal` for the
/// full pipeline.
enum RealSpeakerDiarizationService {

    enum Failure: Error, LocalizedError {
        case noAudioTrack
        case readFailed(String)
        case modelNotReady

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:  return "The file has no audio track to diarize."
            case .readFailed(let m): return "Could not read audio: \(m)"
            case .modelNotReady: return "Speaker models are not downloaded yet."
            }
        }
    }

    /// Run the full pipeline on `url`. Thread-safe — the diarizer and
    /// AVAssetReader are local to this call.
    /// - Parameters:
    ///   - url: any file AVAsset can open (mov, mp4, wav, m4a…).
    ///   - models: model paths obtained from `SherpaModelStore`.
    ///   - clusteringThreshold: cosine distance threshold for speaker
    ///     separation. Lower → splits more aggressively.
    ///     sherpa-onnx ships `0.5` as its library default, which is
    ///     tuned for multi-speaker podcasts/meetings and reliably
    ///     shatters a clean monologue into 2–3 clusters (pitch shifts,
    ///     mic noise, and laughs each produce a stray micro-cluster).
    ///     We default to `0.9`, which the pyannote/3D-Speaker
    ///     community recommends for content where undersplitting is
    ///     preferable to oversplitting — real distinct speakers in an
    ///     interview still separate cleanly at this value.
    static func run(
        url: URL,
        models: (segmentation: URL, embedding: URL),
        clusteringThreshold: Float = 0.9
    ) async throws -> [SherpaSpeakerSegment] {
        let samples = try await extractMono16kFloat(url: url)
        guard !samples.isEmpty else { return [] }

        let diarizer = try SherpaSpeakerDiarizer(
            segmentationModelPath: models.segmentation.path,
            embeddingModelPath: models.embedding.path,
            clusteringThreshold: clusteringThreshold
        )

        guard diarizer.requiredSampleRate == 16_000 else {
            throw Failure.readFailed(
                "Unexpected diarizer sample rate \(diarizer.requiredSampleRate)"
            )
        }

        let raw = try diarizer.process(samples: samples)
        logRawDiarization(url: url, raw: raw, threshold: clusteringThreshold)
        let collapsed = collapseMinorSpeakers(raw)
        logCollapseResult(raw: raw, collapsed: collapsed)
        let densified = densifyByFirstAppearance(collapsed)
        logDensifyResult(collapsed: collapsed, densified: densified)
        return densified
    }

    /// Remap sherpa-onnx cluster IDs (which are arbitrary integers from
    /// the clustering algorithm — e.g. `{2, 5, 7}` after `collapseMinorSpeakers`
    /// drops minor clusters) to a dense `0..<N` range ordered by first
    /// appearance in source time. Without this the UI would show e.g.
    /// "Speaker 6" as the first detected speaker just because that's the
    /// cluster ID sherpa-onnx happened to assign.
    static func densifyByFirstAppearance(
        _ segments: [SherpaSpeakerSegment]
    ) -> [SherpaSpeakerSegment] {
        guard !segments.isEmpty else { return segments }
        let sorted = segments.sorted { $0.start < $1.start }
        var remap: [Int: Int] = [:]
        var next = 0
        for s in sorted where remap[s.speaker] == nil {
            remap[s.speaker] = next
            next += 1
        }
        if remap.allSatisfy({ $0.key == $0.value }) {
            return segments
        }
        return segments.map {
            SherpaSpeakerSegment(
                start: $0.start,
                end: $0.end,
                speaker: remap[$0.speaker] ?? $0.speaker
            )
        }
    }

    private static func logDensifyResult(
        collapsed: [SherpaSpeakerSegment],
        densified: [SherpaSpeakerSegment]
    ) {
        let beforeIDs = Set(collapsed.map(\.speaker)).sorted()
        let afterIDs = Set(densified.map(\.speaker)).sorted()
        guard beforeIDs != afterIDs else {
            print("🗣 [diarize] densifyByFirstAppearance: no-op, IDs already dense \(beforeIDs)")
            return
        }
        print("🗣 [diarize] densifyByFirstAppearance: \(beforeIDs) → \(afterIDs)")
    }

    /// Print a one-line summary of the raw clustering result so we can
    /// see if the embedding stage is the bottleneck (e.g. only 1 cluster
    /// for an obvious 2-speaker recording → lower `clusteringThreshold`
    /// next time). Per-speaker airtime + share helps eyeball whether
    /// the post-processing collapse will fire.
    private static func logRawDiarization(
        url: URL,
        raw: [SherpaSpeakerSegment],
        threshold: Float
    ) {
        var totals: [Int: Double] = [:]
        var grand: Double = 0
        for s in raw {
            let d = max(0, s.end - s.start)
            totals[s.speaker, default: 0] += d
            grand += d
        }
        let perSpk = totals.keys.sorted().map { id -> String in
            let dur = totals[id] ?? 0
            let pct = grand > 0 ? Int((dur / grand) * 100) : 0
            return "spk\(id)=\(String(format: "%.1f", dur))s/\(pct)%"
        }.joined(separator: " ")
        print("🗣 [diarize] raw \(url.lastPathComponent) threshold=\(threshold) clusters=\(totals.count) segments=\(raw.count) total=\(String(format: "%.1f", grand))s \(perSpk)")
    }

    /// Print the after-collapse summary so we can tell whether
    /// `collapseMinorSpeakers` was responsible for an unexpected
    /// 1-speaker result, vs the embedding stage.
    private static func logCollapseResult(
        raw: [SherpaSpeakerSegment],
        collapsed: [SherpaSpeakerSegment]
    ) {
        let rawClusters = Set(raw.map(\.speaker)).count
        let outClusters = Set(collapsed.map(\.speaker)).count
        if rawClusters != outClusters {
            print("🗣 [diarize] collapseMinorSpeakers: \(rawClusters) → \(outClusters) cluster(s) (segments \(raw.count) → \(collapsed.count))")
        } else {
            print("🗣 [diarize] collapseMinorSpeakers: kept \(outClusters) cluster(s) (no merging applied)")
        }
    }

    /// Post-process the raw diarization to merge away spurious clusters
    /// that survive the embedding model on clean single-speaker audio.
    ///
    /// Strategy: only force-merge everything down to one speaker when
    /// the dominant cluster is *overwhelmingly* dominant
    /// (`dominanceFraction = 0.97` by default). At lower dominance
    /// (anywhere up to 96%) we keep the multi-speaker result — a real
    /// interview with a host at 15% airtime and a guest at 85% would
    /// have collapsed to one speaker under the previous 0.8 threshold.
    ///
    /// Below the force-collapse line, individual minor clusters are
    /// dropped only if they are BOTH below `minFraction` of the
    /// dominant total AND below `minDuration` seconds — i.e. truly
    /// micro-clusters from pitch shifts / noise / a single laugh.
    /// Anything ≥ 5% of the dominant or ≥ 2s of total speech survives,
    /// which catches real second/third speakers in panel discussions.
    static func collapseMinorSpeakers(
        _ segments: [SherpaSpeakerSegment],
        dominanceFraction: Double = 0.97,
        minFraction: Double = 0.05,
        minDuration: Double = 2.0
    ) -> [SherpaSpeakerSegment] {
        guard !segments.isEmpty else { return segments }

        var totals: [Int: Double] = [:]
        var grandTotal: Double = 0
        for s in segments {
            let d = max(0, s.end - s.start)
            totals[s.speaker, default: 0] += d
            grandTotal += d
        }
        guard grandTotal > 0,
              let (dominantID, dominantTotal) = totals.max(by: { $0.value < $1.value })
        else { return segments }

        let dominantShare = dominantTotal / grandTotal
        let forceCollapseAll = dominantShare >= dominanceFraction

        let keepIDs: Set<Int> = Set(totals.compactMap { id, total -> Int? in
            if id == dominantID { return id }
            if forceCollapseAll { return nil }
            // Otherwise keep only clusters that are both a sizable
            // fraction of the dominant AND above an absolute floor.
            if total / dominantTotal >= minFraction && total >= minDuration {
                return id
            }
            return nil
        })

        if keepIDs.count == totals.count { return segments }

        let rewritten = segments.map {
            keepIDs.contains($0.speaker)
                ? $0
                : SherpaSpeakerSegment(start: $0.start, end: $0.end, speaker: dominantID)
        }
        return coalesceAdjacent(rewritten)
    }

    private static func coalesceAdjacent(
        _ segments: [SherpaSpeakerSegment]
    ) -> [SherpaSpeakerSegment] {
        var out: [SherpaSpeakerSegment] = []
        out.reserveCapacity(segments.count)
        for s in segments {
            if var last = out.last,
               last.speaker == s.speaker,
               s.start - last.end < 0.05 {
                last = SherpaSpeakerSegment(
                    start: last.start,
                    end: max(last.end, s.end),
                    speaker: last.speaker
                )
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    // MARK: - Audio extraction

    /// Pull the whole audio track off disk, resampled to 16 kHz mono
    /// Float32 in `[-1, 1]`. AVAssetReader handles the resample when
    /// we pass the target format in `outputSettings`.
    private static func extractMono16kFloat(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw Failure.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure.readFailed(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.readFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        var samples: [Float] = []
        samples.reserveCapacity(16_000 * 60)  // ~1 min as a cheap starting hint

        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }

            var buf = [UInt8](repeating: 0, count: length)
            let err = buf.withUnsafeMutableBytes { ptr -> OSStatus in
                CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: length,
                    destination: ptr.baseAddress!
                )
            }
            guard err == kCMBlockBufferNoErr else { continue }

            let floatCount = length / MemoryLayout<Float>.size
            buf.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Float.self)
                samples.append(contentsOf: UnsafeBufferPointer(start: p.baseAddress, count: floatCount))
            }
        }

        if reader.status == .failed {
            throw Failure.readFailed(reader.error?.localizedDescription ?? "reader failed")
        }

        return samples
    }

    // MARK: - Cue → speaker mapping helper

    /// Pick the speaker whose diarization segment has the greatest
    /// overlap with `range` in source time. Ties broken by whichever
    /// speaker's segment covers the midpoint of `range`. Returns `nil`
    /// when there is no overlap at all — callers should then leave the
    /// cue's existing speakerID alone.
    static func dominantSpeaker(
        for range: ClosedRange<Double>,
        in diarization: [SherpaSpeakerSegment]
    ) -> Int? {
        guard !diarization.isEmpty else { return nil }
        let start = range.lowerBound
        let end = range.upperBound
        guard end > start else { return nil }

        var bestSpeaker: Int? = nil
        var bestOverlap: Double = 0
        for seg in diarization {
            let lo = max(start, seg.start)
            let hi = min(end, seg.end)
            let overlap = hi - lo
            guard overlap > 0 else { continue }
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = seg.speaker
            }
        }
        return bestSpeaker
    }
}
