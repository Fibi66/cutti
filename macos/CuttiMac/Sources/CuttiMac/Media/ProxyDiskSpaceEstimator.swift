import Foundation
import CuttiKit

/// Estimates how many bytes a ProRes 422 + LPCM proxy will consume on
/// disk, so we can fail fast when the volume cannot fit the output.
///
/// AVAssetExportSession with `AVAssetExportPresetAppleProRes422LPCM`
/// preserves the source resolution, so the proxy's video bitrate is a
/// function of `width * height * fps`. The constants below are
/// calibrated against Apple's published ProRes 422 data rates (75 Mbps
/// at 720p30, 147 Mbps at 1080p30, 588 Mbps at 4K30).
///
/// `bytesPerSecond ≈ width * height * fps * 0.3` lands within ~10 % of
/// Apple's table across that range without needing a lookup table.
enum ProxyDiskSpaceEstimator {

    /// Estimated proxy output size in bytes. Returns 0 if `analysis`
    /// is missing or has degenerate dimensions / duration.
    static func estimatedProxyBytes(
        for analysis: AnalysisSummary
    ) -> Int64 {
        let width = max(0, analysis.width)
        let height = max(0, analysis.height)
        let duration = max(0.0, analysis.durationSeconds)
        // Some sources (audio-only, malformed) report 0 fps. Use 30 as
        // a sane default so the estimate doesn't collapse to zero.
        let fps = analysis.nominalFPS > 0 ? analysis.nominalFPS : 30.0
        guard width > 0, height > 0, duration > 0.05 else {
            return 0
        }

        // Video: ProRes 422 ≈ 0.3 bytes / pixel / frame.
        let videoBytesPerSecond = Double(width) * Double(height) * fps * 0.3
        // Audio: LPCM 48 kHz 16-bit stereo ≈ 192 KB/s. 200 KB/s is a
        // fine over-estimate.
        let audioBytesPerSecond: Double = analysis.hasAudio ? 200_000 : 0
        let totalBytes = (videoBytesPerSecond + audioBytesPerSecond) * duration
        // 10 % safety margin so a 99 %-full disk doesn't silently fail
        // mid-export when our estimate is slightly low.
        return Int64(totalBytes * 1.1)
    }

    /// Reads free bytes on the volume that holds `url`. Returns nil if
    /// the system can't tell us — caller should treat that as "skip the
    /// precheck", not "definitely full".
    ///
    /// Prefers `volumeAvailableCapacityForImportantUsageKey` (honors
    /// purgeable space + iCloud) and falls back to
    /// `volumeAvailableCapacityKey`.
    static func freeBytes(forVolumeContaining url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return nil
        }
        if let importantBytes = values.volumeAvailableCapacityForImportantUsage {
            return Int64(importantBytes)
        }
        if let plainBytes = values.volumeAvailableCapacity {
            return Int64(plainBytes)
        }
        return nil
    }
}
