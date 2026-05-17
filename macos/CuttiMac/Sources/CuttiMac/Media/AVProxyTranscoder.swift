import AVFoundation
import Foundation

struct AVProxyTranscoder: ProxyTranscoding {

    /// If `exportSession.progress` does not advance for this long while
    /// the session is `.exporting`, we treat the export as wedged and
    /// cancel it. Calibrated for very large 4K sources on slower drives:
    /// real exports hit at least one progress sample in <20 s; 90 s is a
    /// generous wedge threshold without making the user wait forever.
    static let stallTimeoutSeconds: TimeInterval = 90

    func transcode(
        sourceURL: URL,
        destinationURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async -> TranscodeResult {
        let asset = AVURLAsset(url: sourceURL)

        // Pick the preset based on the source's codec. H.264 / HEVC
        // sources passthrough (just remux into .mov) — Apple Silicon
        // hardware-decodes them at full quality, and re-encoding to
        // ProRes 422 at source resolution would balloon a 400 MB HEVC
        // 4K file into ~200 GB on disk. Everything else still goes
        // through the full ProRes 422 LPCM re-encode so timeline
        // scrubbing stays smooth.
        let codec = await ProxyTranscodePlanner.detectVideoCodec(url: sourceURL)
        let presetName: String
        if let codec, ProxyTranscodePlanner.isAppleSiliconNativePlayback(codec) {
            presetName = AVAssetExportPresetPassthrough
        } else {
            presetName = AppleSiliconProxySettings.exportPreset
        }

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: presetName
        ) else {
            let failureMessage = "Export failed: Unsupported Apple-native export preset"
            if FFmpegProxyFallback.isEligible(primaryFailure: failureMessage) {
                return .fallbackEligibleFailure(failureMessage)
            } else {
                return .failure(failureMessage)
            }
        }

        // Remove existing destination file if present
        if FileManager.default.fileExists(atPath: destinationURL.path()) {
            do {
                try FileManager.default.removeItem(at: destinationURL)
            } catch {
                return .failure("Export failed: Could not remove existing file: \(error.localizedDescription)")
            }
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = AppleSiliconProxySettings.outputFileType

        // AVAssetExportSession is an Obj-C completion-handler API bridged
        // as async; it isn't `Sendable` in Swift 6, so we capture it via
        // `nonisolated(unsafe)` exactly the way `AIVideoExporter`
        // already does (see AIVideoExporter.runExportSession).
        nonisolated(unsafe) let unsafeSession = exportSession

        // Polling task: forwards `exportSession.progress` to the caller
        // and tracks "no progress for N seconds" so we can flag a
        // wedged export. Cancelled in a `defer` after `export()`
        // returns.
        let stallSeconds = Self.stallTimeoutSeconds
        let stallSignal = ActorIsolatedFlag()
        let progressTask = Task { @Sendable in
            var lastProgress: Float = -1
            var lastChangeAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                let current = unsafeSession.progress
                if current != lastProgress {
                    lastProgress = current
                    lastChangeAt = Date()
                    progress(Double(current))
                } else if Date().timeIntervalSince(lastChangeAt) > stallSeconds,
                          unsafeSession.status == .exporting {
                    await stallSignal.set()
                    unsafeSession.cancelExport()
                    return
                }
            }
        }

        // Swift Concurrency does not propagate cancellation into
        // AVAssetExportSession.export() — we MUST hook it via
        // `withTaskCancellationHandler` in the same scope as the
        // `await session.export()` call. Wrapping `cancelExport()` in
        // a separate Task would be a no-op (unstructured tasks don't
        // inherit cancellation).
        await withTaskCancellationHandler {
            await unsafeSession.export()
        } onCancel: {
            unsafeSession.cancelExport()
        }

        progressTask.cancel()

        // Distinguish three end-states for the caller:
        // - parent task cancelled → throw-equivalent: return a failure
        //   tagged so MediaCore can detect + clean up.
        // - watchdog fired (stall) → explicit failure with that reason.
        // - normal AVF status → existing logic.
        if Task.isCancelled {
            return .failure("Export cancelled")
        }
        if await stallSignal.isSet {
            return .failure("Export stalled — no progress for \(Int(stallSeconds))s")
        }

        switch unsafeSession.status {
        case .completed:
            // Forward a final 1.0 sample so the UI doesn't end at 99 %.
            progress(1.0)
            return .success

        case .failed, .cancelled:
            let errorDescription = unsafeSession.error?.localizedDescription ?? "Unknown error"
            let failureMessage = "Export failed: \(errorDescription)"

            if FFmpegProxyFallback.isEligible(primaryFailure: failureMessage) {
                return .fallbackEligibleFailure(failureMessage)
            } else {
                return .failure(failureMessage)
            }

        default:
            return .failure("Export ended in unexpected state: \(unsafeSession.status.rawValue)")
        }
    }
}

/// One-shot boolean flag, settable from any task. Used by the watchdog
/// path inside `AVProxyTranscoder` to communicate "I cancelled this
/// export because it stalled" back to the caller without sharing
/// mutable state across `@Sendable` boundaries.
private actor ActorIsolatedFlag {
    private(set) var isSet: Bool = false
    func set() { isSet = true }
}
