import Foundation
import AVFoundation

/// Generates + caches a downsampled peak envelope for every audio
/// source used on the timeline. One envelope per sourceVideoID, stored
/// as a simple JSON blob at `media/waveforms/<id>.json` — regenerated
/// lazily the first time a segment from that source shows up on the
/// audio lane.
///
/// The envelope is an array of `Float` samples in [0, 1] representing
/// per-bucket max absolute PCM magnitude across the whole source
/// duration. SegmentChip scales it to its on-screen width by sampling
/// the range the segment actually plays.
@MainActor
final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()

    /// Target bucket count for every cached envelope. Striking a
    /// balance between visual detail at large pixelsPerSecond and
    /// storage/render cost — 600 buckets renders ~20KB JSON per
    /// clip and draws smoothly as horizontal bars.
    static let bucketCount = 600

    @Published private(set) var envelopes: [UUID: [Float]] = [:]
    private var inFlight: Set<UUID> = []

    func envelope(for id: UUID) -> [Float]? { envelopes[id] }

    /// Kick off generation if we don't already have it.
    func prime(mediaID: UUID, sourceURL: URL, waveformDir: URL) {
        if envelopes[mediaID] != nil || inFlight.contains(mediaID) { return }
        inFlight.insert(mediaID)
        let cacheURL = waveformDir.appending(path: "\(mediaID.uuidString).json")
        Task.detached(priority: .utility) { [weak self] in
            if let disk = try? Data(contentsOf: cacheURL),
               let arr = try? JSONDecoder().decode([Float].self, from: disk) {
                await MainActor.run {
                    self?.envelopes[mediaID] = arr
                    self?.inFlight.remove(mediaID)
                }
                return
            }
            let env = await WaveformStore.generate(from: sourceURL)
            if let env, let data = try? JSONEncoder().encode(env) {
                try? FileManager.default.createDirectory(
                    at: waveformDir, withIntermediateDirectories: true
                )
                try? data.write(to: cacheURL, options: .atomic)
            }
            await MainActor.run {
                if let env { self?.envelopes[mediaID] = env }
                self?.inFlight.remove(mediaID)
            }
        }
    }

    private static func generate(from url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else {
            return nil
        }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // Determine total sample count and per-bucket size. We use the
        // track's natural sample rate to estimate total, falling back
        // to a conservative 44.1k×duration estimate.
        let desc = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
        let sampleRate: Double = {
            if let d = desc, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                return asbd.mSampleRate > 0 ? asbd.mSampleRate : 44100
            }
            return 44100
        }()
        let totalSamples = Int(duration * sampleRate)
        let buckets = bucketCount
        let samplesPerBucket = max(1, totalSamples / buckets)

        var env = [Float](repeating: 0, count: buckets)
        var currentBucket = 0
        var samplesAccumulated = 0
        var peakInBucket: Int16 = 0

        while reader.status == .reading, let buf = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buf) else {
                CMSampleBufferInvalidate(buf)
                continue
            }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard let dataPointer else {
                CMSampleBufferInvalidate(buf)
                continue
            }
            let sampleCount = length / MemoryLayout<Int16>.size
            dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { ptr in
                for i in 0..<sampleCount {
                    let v = ptr[i]
                    let mag = v == Int16.min ? Int16.max : abs(v)
                    if mag > peakInBucket { peakInBucket = mag }
                    samplesAccumulated += 1
                    if samplesAccumulated >= samplesPerBucket {
                        if currentBucket < buckets {
                            env[currentBucket] = Float(peakInBucket) / Float(Int16.max)
                        }
                        currentBucket += 1
                        samplesAccumulated = 0
                        peakInBucket = 0
                    }
                }
            }
            CMSampleBufferInvalidate(buf)
        }
        if currentBucket < buckets, peakInBucket > 0 {
            env[currentBucket] = Float(peakInBucket) / Float(Int16.max)
        }
        return env
    }
}
