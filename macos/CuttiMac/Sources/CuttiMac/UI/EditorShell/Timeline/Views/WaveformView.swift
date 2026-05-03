// Auto-extracted from TimelineDock.swift — see commit log for rationale.
// Contents are moved verbatim; no behaviour changes.

import AppKit
import SwiftUI
import AVFoundation
import CuttiKit

// MARK: - Waveform View

struct WaveformView: View {
    let videoURL: URL
    let duration: Double
    let segments: [TimelineSegment]
    let width: CGFloat
    let height: CGFloat
    let pointsPerSecond: CGFloat

    @State private var samples: [Float] = []

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }

            let mid = size.height / 2
            // Obsidian-style discrete bars: ~3px wide with a 2px gap.
            let barWidth: CGFloat = 3
            let barGap: CGFloat = 2
            let stride = barWidth + barGap
            let barCount = max(1, Int(size.width / stride))
            let samplesPerBar = max(1, samples.count / barCount)

            let peak = samples.max() ?? 1
            let scale: CGFloat = peak > 0 ? 1.0 / CGFloat(peak) : 1.0

            for bar in 0..<barCount {
                let startIdx = bar * samplesPerBar
                let endIdx = min(samples.count, startIdx + samplesPerBar)
                guard startIdx < endIdx else { break }
                var peakInBar: Float = 0
                for j in startIdx..<endIdx { peakInBar = max(peakInBar, samples[j]) }

                let x = CGFloat(bar) * stride
                let normalized = CGFloat(peakInBar) * scale
                let amplitude = max(1, normalized * mid * 0.9)

                let seconds = duration * Double(startIdx) / Double(samples.count)
                let isKept = segments.isEmpty || segments.contains { seconds >= $0.range.startSeconds && seconds <= $0.range.endSeconds }
                let color = isKept ? EditorShellStyle.obA1.opacity(0.85) : EditorShellStyle.obA1.opacity(0.25)

                let rect = CGRect(x: x, y: mid - amplitude, width: barWidth, height: amplitude * 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        // Bucket width to 32pt steps and debounce 140ms (same reasoning
        // as SegmentFilmstrip): trim/zoom gestures change `width` by one
        // point per mouse-pixel, and without these two guards each
        // pixel-tick would cancel and restart `AVAssetReader` —
        // dozens of overlapping decode tasks per second saturate the
        // cooperative pool and starve the SwiftUI render loop, which
        // shows up as 15–20 fps lag while dragging segment edges.
        .task(id: "\(videoURL.path)_\(Int(width / 32))") {
            try? await Task.sleep(nanoseconds: 140_000_000)
            if Task.isCancelled { return }
            await generateWaveform()
        }
    }

    private func generateWaveform() async {
        let asset = AVURLAsset(url: videoURL)

        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = audioTracks.first else { return }

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

            var allSamples: [Int16] = []
            while let buffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
                if Task.isCancelled {
                    reader.cancelReading()
                    return
                }
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

            if Task.isCancelled { return }

            // Downsample to target number of visual samples
            let targetCount = Int(width)
            guard !allSamples.isEmpty, targetCount > 0 else { return }

            let windowSize = allSamples.count / targetCount
            guard windowSize > 0 else { return }

            var downsampled: [Float] = []
            for i in 0..<targetCount {
                let start = i * windowSize
                let end = min(start + windowSize, allSamples.count)
                let window = allSamples[start..<end]

                let rms = window.reduce(Float(0)) { acc, sample in
                    let normalized = Float(sample) / Float(Int16.max)
                    return acc + normalized * normalized
                }
                downsampled.append((rms / Float(window.count)).squareRoot())
            }

            await MainActor.run {
                self.samples = downsampled
            }
        } catch {
            // Waveform generation failed silently
        }
    }
}

// MARK: - Segment Waveform (waveform for a specific time range)

struct SegmentWaveform: View {
    let videoURL: URL
    let startSeconds: Double
    let endSeconds: Double
    let width: CGFloat
    let height: CGFloat

    @State private var samples: [Float] = []

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }

            let mid = size.height / 2
            // Discrete Obsidian-style bars.
            let barWidth: CGFloat = 3
            let barGap: CGFloat = 2
            let stride = barWidth + barGap
            let barCount = max(1, Int(size.width / stride))
            let samplesPerBar = max(1, samples.count / barCount)
            let peak = samples.max() ?? 1
            let scale: CGFloat = peak > 0 ? 1.0 / CGFloat(peak) : 1.0

            for bar in 0..<barCount {
                let startIdx = bar * samplesPerBar
                let endIdx = min(samples.count, startIdx + samplesPerBar)
                guard startIdx < endIdx else { break }
                var peakInBar: Float = 0
                for j in startIdx..<endIdx { peakInBar = max(peakInBar, samples[j]) }

                let x = CGFloat(bar) * stride
                let normalized = CGFloat(peakInBar) * scale
                let amplitude = max(1, normalized * mid * 0.9)

                let rect = CGRect(x: x, y: mid - amplitude, width: barWidth, height: amplitude * 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(EditorShellStyle.obA1.opacity(0.85)))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        // Bucket width to 32pt steps and debounce 140ms — same reasoning
        // as SegmentFilmstrip. Without these guards, every pixel of
        // mouse movement during a trim or overlay-resize gesture would
        // cancel-and-restart AVAssetReader. The `Task.isCancelled`
        // checks inside the read loop only fire between buffers, so
        // mid-decode cancels still let chunks of work run; dozens of
        // overlapping decoders per second saturate the cooperative
        // thread pool and the timeline drops to ~15–20 fps. Sleeping
        // 140ms first means transient task ids cancel before any
        // generator work fires; only the user pausing for ≥140ms
        // commits to a real decode.
        .task(id: "\(videoURL.path)_\(String(format: "%.1f", startSeconds))_\(String(format: "%.1f", endSeconds))_\(Int(width / 32))") {
            try? await Task.sleep(nanoseconds: 140_000_000)
            if Task.isCancelled { return }
            await generateWaveform()
        }
    }

    private func generateWaveform() async {
        let asset = AVURLAsset(url: videoURL)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = audioTracks.first else { return }

            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                end: CMTime(seconds: endSeconds, preferredTimescale: 600)
            )
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(output)
            reader.startReading()

            var allSamples: [Int16] = []
            while let buffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
                if Task.isCancelled {
                    reader.cancelReading()
                    return
                }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { ptr in
                    guard let base = ptr.baseAddress else { return }
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
                }
                let count = length / MemoryLayout<Int16>.size
                data.withUnsafeBytes { ptr in
                    guard let bound = ptr.bindMemory(to: Int16.self).baseAddress else { return }
                    allSamples.append(contentsOf: UnsafeBufferPointer(start: bound, count: count))
                }
            }

            if Task.isCancelled { return }

            let targetCount = max(1, Int(width))
            guard !allSamples.isEmpty else { return }
            let windowSize = max(1, allSamples.count / targetCount)

            var downsampled: [Float] = []
            for i in 0..<targetCount {
                let start = i * windowSize
                let end = min(start + windowSize, allSamples.count)
                guard start < end else { break }
                let window = allSamples[start..<end]
                let rms = window.reduce(Float(0)) { acc, s in
                    let n = Float(s) / Float(Int16.max)
                    return acc + n * n
                }
                downsampled.append((rms / Float(window.count)).squareRoot())
            }

            await MainActor.run { self.samples = downsampled }
        } catch {}
    }
}
