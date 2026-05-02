import Foundation
import AVFoundation

/// Materializes a synthesized SFX into a cached .wav file on disk so
/// the normal media-import pipeline (`MediaCore.importLocalVideo` →
/// proxy transcode → `MediaAssetRecord`) can ingest it just like any
/// other audio file the user dragged in.
///
/// The cache lives at
/// `~/Library/Application Support/cutti/sfx-cache/<kind>.wav`.
/// Because `SFXSynthesizer` uses a seeded PRNG, the output is
/// deterministic — once a file is written we never need to regenerate
/// it, so the cache key is simply the kind's raw value.
enum SFXRenderer {
    /// Returns the URL of a cached .wav for `kind`, synthesizing and
    /// writing it on first use. Subsequent calls are O(1) file-exists
    /// checks.
    static func ensureRendered(_ kind: SFXKind) throws -> URL {
        let url = cacheURL(for: kind)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeWAV(samples: SFXSynthesizer.render(kind), to: url)
        return url
    }

    /// Fully qualified cache URL for a given effect. Exposed so the
    /// library sheet can check existence / invalidate on demand
    /// (e.g. after a synthesizer bug-fix the user can hit "Rebuild").
    static func cacheURL(for kind: SFXKind) -> URL {
        cacheDirectory().appendingPathComponent("\(kind.rawValue).wav")
    }

    /// Purges the entire cache. Useful when bumping SFXSynthesizer's
    /// tuning — older .wav files become stale otherwise. Not wired to
    /// any UI today; kept here so a future "Rebuild SFX" menu item is
    /// a one-liner.
    static func clearCache() throws {
        let dir = cacheDirectory()
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - Private

    private static func cacheDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("cutti", isDirectory: true)
            .appendingPathComponent("sfx-cache", isDirectory: true)
    }

    /// Writes mono Float32 samples to a 48kHz 16-bit PCM WAV via
    /// AVAudioFile. 16-bit is used (not Float32) so the file opens in
    /// QuickTime / ffmpeg / any DAW without fuss.
    private static func writeWAV(samples: [Float], to url: URL) throws {
        let sampleRate = SFXSynthesizer.sampleRate
        guard let srcFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                            channels: 1) else {
            throw SFXRendererError.formatCreationFailed
        }

        // AVAudioFile's file-side settings: 16-bit signed, mono, 48kHz.
        // AVAudioFile handles the Float32 → Int16 conversion internally
        // so we just feed it the Float32 buffer.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: srcFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw SFXRendererError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }
}

enum SFXRendererError: LocalizedError {
    case formatCreationFailed
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create audio format for SFX rendering."
        case .bufferCreationFailed:
            return "Failed to allocate SFX render buffer."
        }
    }
}
