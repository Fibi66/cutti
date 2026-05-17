import AVFoundation
import CoreMedia
import Foundation
import CuttiKit

/// Two-way decision for how to "transcode" a source into the editor's
/// proxy file: either a pure remux (passthrough) when the source is in a
/// codec Apple Silicon decodes natively, or a full ProRes 422 LPCM
/// re-encode for legacy / odd codecs.
///
/// Why this matters: `AVAssetExportPresetAppleProRes422LPCM` preserves
/// the source resolution, so an HEVC 4K/60 input that lives on disk as
/// a tidy ~400 MB file balloons to ~200 GB once it's been blown up into
/// ProRes. Users with normal-sized SSDs hit a "Not enough free disk
/// space" wall on import and can't get past it. On Apple Silicon both
/// H.264 and HEVC scrub fluidly through the hardware decoder, so we can
/// safely skip the re-encode for those codecs and use the source as the
/// proxy. The estimator + transcoder agree on this decision so the disk
/// precheck reflects the actual cost.
enum ProxyTranscodePlan: Equatable, Sendable {
    /// Source is already in a codec the editor can play back smoothly.
    /// Remux into a `.mov` container without re-encoding.
    case passthrough(estimatedOutputBytes: Int64)
    /// Re-encode to ProRes 422 LPCM at source resolution. Used for
    /// anything we don't recognise as Apple-Silicon-native.
    case proresReencode(estimatedOutputBytes: Int64)

    /// Preset name to hand `AVAssetExportSession`.
    var preset: String {
        switch self {
        case .passthrough: return AVAssetExportPresetPassthrough
        case .proresReencode: return AVAssetExportPresetAppleProRes422LPCM
        }
    }

    /// Disk-space budget the import precheck should compare against
    /// `freeBytes`.
    var estimatedOutputBytes: Int64 {
        switch self {
        case .passthrough(let b), .proresReencode(let b): return b
        }
    }
}

enum ProxyTranscodePlanner {

    /// FourCC codec of the source's first video track, or `nil` if the
    /// asset has no video track or AVFoundation can't read it. Cheap —
    /// only loads the format description, not actual sample data.
    static func detectVideoCodec(url: URL) async -> FourCharCode? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descs = try? await track.load(.formatDescriptions),
              let desc = descs.first else { return nil }
        return CMFormatDescriptionGetMediaSubType(desc)
    }

    /// Codecs that Apple Silicon decodes in hardware and that the editor
    /// can scrub through without needing a ProRes intermediate. Anything
    /// outside this set still gets re-encoded so timeline scrubbing
    /// stays responsive.
    static func isAppleSiliconNativePlayback(_ codec: FourCharCode) -> Bool {
        // CoreMedia constants for the families we care about.
        let h264 = kCMVideoCodecType_H264         // 'avc1'
        let hevc = kCMVideoCodecType_HEVC         // 'hvc1'
        // Some sources tag HEVC as 'hev1' (parameter sets in the
        // elementary stream rather than in `hvcC`). Treat it as HEVC.
        let hev1: FourCharCode = 0x68657631       // 'hev1'
        return codec == h264 || codec == hevc || codec == hev1
    }

    /// Source file size on disk, used as the passthrough estimate.
    /// Returns 0 if the file is unreadable (shouldn't happen at this
    /// point in the import — the analyzer already opened it).
    static func sourceFileSize(url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// Pick the plan. Falls back to the ProRes path if codec detection
    /// fails so we never silently downgrade quality for a format we
    /// couldn't classify.
    static func plan(
        url: URL,
        analysis: AnalysisSummary
    ) async -> ProxyTranscodePlan {
        let codec = await detectVideoCodec(url: url)
        if let codec, isAppleSiliconNativePlayback(codec) {
            // Output of `AVAssetExportPresetPassthrough` is essentially
            // the source's elementary streams in a (possibly new) .mov
            // container. Add a generous 10% margin for container
            // overhead + safety so a 99 %-full disk doesn't fail mid-
            // export when our estimate is slightly low.
            let bytes = Int64(Double(max(0, sourceFileSize(url: url))) * 1.1)
            return .passthrough(estimatedOutputBytes: max(bytes, 1))
        }
        let proresBytes = ProxyDiskSpaceEstimator.estimatedProxyBytes(for: analysis)
        return .proresReencode(estimatedOutputBytes: proresBytes)
    }
}
