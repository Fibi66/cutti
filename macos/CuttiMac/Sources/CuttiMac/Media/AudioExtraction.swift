import AVFoundation
import Foundation

/// Extracts the audio track of an arbitrary media file into a small,
/// libsndfile-readable WAV at a fixed sample rate and channel layout.
///
/// Why this exists: the Qwen3-ASR sidecar feeds the input path to
/// `librosa.load`, which delegates to libsndfile (via PySoundFile)
/// when the container is recognised. libsndfile supports WAV / FLAC
/// / OGG / etc. but **not** the QuickTime `.mov` container or other
/// AV containers cutti commonly hands it. When PySoundFile fails,
/// librosa silently falls back to the `audioread` path, which on
/// large files (>10 GB) spawns a single-threaded ffmpeg / coreaudio
/// pipeline that streams every byte through Python — for a 51 GB
/// 24-minute proxy that fallback can take 10+ minutes before the
/// model even sees a sample.
///
/// AVAssetReader, by contrast, decodes only the audio track and uses
/// hardware-accelerated AAC / Apple Lossless / etc. decoders. A
/// 24-minute clip extracted to 16 kHz / mono / 16-bit PCM is ~46 MB
/// regardless of source bitrate, and the extraction finishes in a
/// few seconds — even on a multi-GB ProRes / RAW source.
///
/// We extract to 16 kHz mono because Qwen3-ASR internally resamples
/// to that anyway. Doing the resample in AVFoundation rather than in
/// Python both shrinks the file the sidecar reads and skips redundant
/// work downstream.
enum AudioExtraction {

    /// Extract `sourceURL`'s primary audio track to a temp WAV at
    /// 16 kHz mono 16-bit PCM. Returns the temp URL on success; the
    /// caller is responsible for deleting it (typical pattern: pass
    /// it to the sidecar, then `try? FileManager.default.removeItem`
    /// in a `defer`).
    ///
    /// Throws if the source has no audio track or if AVAssetReader /
    /// AVAssetWriter fails. The thrown error is the AV framework's
    /// own, surfaced verbatim for logging.
    static func extractMono16kWav(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioExtractionError.noAudioTrack
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutti-asr-extract", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent(UUID().uuidString + ".wav")

        let reader = try AVAssetReader(asset: asset)
        // Ask AVAssetReader to give us interleaved 16-bit PCM at the
        // source sample rate. We resample to 16 kHz ourselves below
        // — letting AVAssetReader resample directly works on most
        // codecs but silently no-ops on a few exotic ones, so we do
        // the conversion explicitly via AVAudioConverter for
        // determinism.
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerSettings)
        guard reader.canAdd(readerOutput) else {
            throw AudioExtractionError.readerCannotAddOutput
        }
        reader.add(readerOutput)

        // Source format info — needed to build the AVAudioConverter.
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        guard let firstDesc = formatDescriptions.first,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(firstDesc) else {
            throw AudioExtractionError.missingFormatDescription
        }
        let srcSampleRate = asbdPtr.pointee.mSampleRate
        let srcChannelCount = AVAudioChannelCount(max(1, Int(asbdPtr.pointee.mChannelsPerFrame)))

        guard let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: srcSampleRate,
            channels: srcChannelCount,
            interleaved: true
        ) else {
            throw AudioExtractionError.failedToBuildSourceFormat
        }

        let dstSampleRate: Double = 16_000
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: dstSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioExtractionError.failedToBuildDestinationFormat
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw AudioExtractionError.failedToBuildConverter
        }

        // AVAudioFile writes a well-formed WAV (RIFF / fmt / data
        // chunks) that libsndfile / PySoundFile reads natively. We
        // open it for writing in PCM Int16 mono @ 16 kHz so the
        // header matches what's actually appended.
        let outFile = try AVAudioFile(
            forWriting: dest,
            settings: dstFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        guard reader.startReading() else {
            throw AudioExtractionError.readerFailedToStart(reader.error?.localizedDescription ?? "unknown")
        }

        // Pump source buffers through the converter and write the
        // converted frames to the WAV file. The converter pulls input
        // on demand via an input block — we hand it the next source
        // buffer (or .endOfStream when AVAssetReader is exhausted).
        var sourceExhausted = false

        while true {
            // Up to 1 second of mono 16 kHz output per pass keeps
            // RAM bounded regardless of how long the source is.
            let outCapacity = AVAudioFrameCount(dstSampleRate)
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: dstFormat,
                frameCapacity: outCapacity
            ) else {
                throw AudioExtractionError.failedToAllocateOutputBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: outBuffer,
                error: &conversionError,
                withInputFrom: { _, outStatus in
                    if sourceExhausted {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        sourceExhausted = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    if let pcm = Self.pcmBuffer(from: sampleBuffer, format: srcFormat) {
                        outStatus.pointee = .haveData
                        return pcm
                    } else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                }
            )

            if let err = conversionError {
                throw err
            }

            if outBuffer.frameLength > 0 {
                try outFile.write(from: outBuffer)
            }

            if status == .endOfStream { break }
            if status == .error { throw AudioExtractionError.converterFailed }
        }

        if reader.status == .failed {
            throw AudioExtractionError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        return dest
    }

    /// Wrap a `CMSampleBuffer` of interleaved Int16 PCM in an
    /// `AVAudioPCMBuffer` so AVAudioConverter can consume it. We
    /// copy the bytes (rather than aliasing CMBlockBuffer storage)
    /// because the converter may retain the buffer past the
    /// sample-buffer's lifetime.
    private static func pcmBuffer(
        from sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = length / bytesPerFrame
        guard frameCount > 0 else { return nil }

        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        guard let dst = pcm.int16ChannelData?[0] else { return nil }
        let bytesCopied = dst.withMemoryRebound(to: UInt8.self, capacity: length) { ptr -> Int in
            var status = noErr
            status = CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: ptr
            )
            return status == noErr ? length : 0
        }
        guard bytesCopied == length else { return nil }
        return pcm
    }
}

enum AudioExtractionError: Error, LocalizedError {
    case noAudioTrack
    case readerCannotAddOutput
    case readerFailedToStart(String)
    case readerFailed(String)
    case missingFormatDescription
    case failedToBuildSourceFormat
    case failedToBuildDestinationFormat
    case failedToBuildConverter
    case failedToAllocateOutputBuffer
    case converterFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "Source has no audio track."
        case .readerCannotAddOutput:
            return "AVAssetReader rejected the audio output."
        case .readerFailedToStart(let s):
            return "AVAssetReader failed to start: \(s)"
        case .readerFailed(let s):
            return "AVAssetReader failed mid-read: \(s)"
        case .missingFormatDescription:
            return "Audio track has no usable format description."
        case .failedToBuildSourceFormat:
            return "Failed to construct AVAudioFormat for source."
        case .failedToBuildDestinationFormat:
            return "Failed to construct AVAudioFormat for destination."
        case .failedToBuildConverter:
            return "Failed to construct AVAudioConverter."
        case .failedToAllocateOutputBuffer:
            return "Failed to allocate output PCM buffer."
        case .converterFailed:
            return "AVAudioConverter reported an error."
        }
    }
}
