import AVFoundation
import Foundation
import CuttiKit

/// Supported export formats.
enum ExportFormat: String, CaseIterable, Identifiable {
    case mov = "MOV (ProRes)"
    case mp4 = "MP4 (H.264)"

    var id: String { rawValue }

    var fileType: AVFileType {
        switch self {
        case .mov: return .mov
        case .mp4: return .mp4
        }
    }

    var fileExtension: String {
        switch self {
        case .mov: return "mov"
        case .mp4: return "mp4"
        }
    }

    var presetName: String {
        switch self {
        case .mov: return AVAssetExportPresetAppleProRes422LPCM
        case .mp4: return AVAssetExportPresetHighestQuality
        }
    }

    var fallbackPresetName: String {
        AVAssetExportPresetPassthrough
    }
}

/// Exports a video by splicing together the kept time ranges from AI analysis.
///
/// Uses `AVMutableComposition` to assemble only the segments the LLM decided
/// to keep, producing a clean final cut without the removed segments.
struct AIVideoExporter: Sendable {

    /// Pure helper: given the current encode fraction (0…1) and elapsed
    /// wall-clock seconds, returns an ETA in seconds. We require at least
    /// 2% progress and 1s of elapsed time before publishing an estimate so
    /// the UI doesn't show wild values during the encoder warm-up window.
    /// Exposed `internal` for unit tests.
    static func estimateRemainingSeconds(
        fraction: Double,
        elapsedSeconds: Double
    ) -> Double? {
        guard fraction > 0.02, elapsedSeconds > 1 else { return nil }
        let total = elapsedSeconds / fraction
        return max(0, total - elapsedSeconds)
    }

    enum ExportError: Error, LocalizedError {
        case noRanges
        case assetLoadFailed(String)
        case noVideoTrack
        case compositionFailed(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noRanges: return "No kept ranges to export."
            case .assetLoadFailed(let msg): return "Asset load failed: \(msg)"
            case .noVideoTrack: return "Source video has no video track."
            case .compositionFailed(let msg): return "Composition failed: \(msg)"
            case .exportFailed(let msg): return "Export failed: \(msg)"
            }
        }
    }

    struct ExportProgress: Sendable {
        let fractionComplete: Double
        let detail: String
        /// Wall-clock seconds since the export started.
        let elapsedSeconds: Double
        /// Best-effort estimate of seconds remaining; nil while there isn't
        /// enough sample data (first ~2 seconds of encoding).
        let estimatedSecondsRemaining: Double?

        init(
            fractionComplete: Double,
            detail: String,
            elapsedSeconds: Double = 0,
            estimatedSecondsRemaining: Double? = nil
        ) {
            self.fractionComplete = fractionComplete
            self.detail = detail
            self.elapsedSeconds = elapsedSeconds
            self.estimatedSecondsRemaining = estimatedSecondsRemaining
        }
    }

    /// Export kept ranges from the source video to the destination URL.
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the original source video (not the proxy).
    ///   - keptRanges: Time ranges to include in the final video.
    ///   - volumes: Per-segment volume levels (0.0–1.0). Empty = all at 1.0.
    ///   - format: Export format (MOV/ProRes or MP4/H.264).
    ///   - destinationURL: Where to write the exported file.
    ///   - onProgress: Called periodically with export progress.
    func export(
        sourceURL: URL,
        keptRanges: [TimeRange],
        volumes: [Double] = [],
        format: ExportFormat = .mov,
        destinationURL: URL,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        guard !keptRanges.isEmpty else {
            throw ExportError.noRanges
        }

        onProgress(ExportProgress(fractionComplete: 0.05, detail: "Loading source video…"))

        let asset = AVURLAsset(url: sourceURL)

        // Load tracks
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else {
            throw ExportError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceAudioTrack = audioTracks.first

        onProgress(ExportProgress(fractionComplete: 0.1, detail: "Building composition…"))

        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.compositionFailed("Could not create video track")
        }

        let compositionAudioTrack: AVMutableCompositionTrack?
        if sourceAudioTrack != nil {
            compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        } else {
            compositionAudioTrack = nil
        }

        // Insert each kept range sequentially into the composition
        var insertionTime = CMTime.zero
        for (index, range) in keptRanges.enumerated() {
            let startTime = CMTime(seconds: range.startSeconds, preferredTimescale: 600)
            let endTime = CMTime(seconds: range.endSeconds, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startTime, end: endTime)

            do {
                try compositionVideoTrack.insertTimeRange(
                    timeRange,
                    of: sourceVideoTrack,
                    at: insertionTime
                )

                if let sourceAudioTrack, let compositionAudioTrack {
                    try compositionAudioTrack.insertTimeRange(
                        timeRange,
                        of: sourceAudioTrack,
                        at: insertionTime
                    )
                }
            } catch {
                throw ExportError.compositionFailed(
                    "Failed to insert range \(index): \(error.localizedDescription)"
                )
            }

            insertionTime = CMTimeAdd(insertionTime, CMTimeSubtract(endTime, startTime))

            let progress = 0.1 + 0.3 * Double(index + 1) / Double(keptRanges.count)
            onProgress(ExportProgress(
                fractionComplete: progress,
                detail: "Composing segment \(index + 1)/\(keptRanges.count)…"
            ))
        }

        // Preserve video orientation
        compositionVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        onProgress(ExportProgress(fractionComplete: 0.4, detail: "Starting export…"))

        // Build audio mix for per-segment volume
        var audioMix: AVMutableAudioMix?
        if let compositionAudioTrack, !volumes.isEmpty {
            let mix = AVMutableAudioMix()
            let params = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            var offset = CMTime.zero
            for (i, range) in keptRanges.enumerated() {
                let startTime = CMTime(seconds: range.startSeconds, preferredTimescale: 600)
                let endTime = CMTime(seconds: range.endSeconds, preferredTimescale: 600)
                let segDuration = CMTimeSubtract(endTime, startTime)
                let vol = Float(volumes[safe: i] ?? 1.0)
                params.setVolume(vol, at: offset)
                offset = CMTimeAdd(offset, segDuration)
            }
            mix.inputParameters = [params]
            audioMix = mix
        }

        // Remove existing file if needed
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        // Export using AVAssetExportSession
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: format.presetName
        ) else {
            // Fallback to passthrough
            guard let fallbackSession = AVAssetExportSession(
                asset: composition,
                presetName: format.fallbackPresetName
            ) else {
                throw ExportError.exportFailed("No compatible export preset available")
            }
            fallbackSession.audioMix = audioMix
            try await runExportSession(fallbackSession, destinationURL: destinationURL, fileType: format.fileType, onProgress: onProgress)
            return
        }

        // Verify format compatibility
        let supportedTypes = exportSession.supportedFileTypes
        let fileType = supportedTypes.contains(format.fileType) ? format.fileType : .mov

        exportSession.audioMix = audioMix
        try await runExportSession(exportSession, destinationURL: destinationURL, fileType: fileType, onProgress: onProgress)
    }

    // MARK: - Composition-based export (with effects)

    /// Export using the shared CompositionBuilder, supporting visual effects and resolution.
    ///
    /// If `subtitleOption` is `.burnIn`, the provided cues are baked into the
    /// video frames. If `.sidecarSRT` / `.sidecarVTT`, a sibling text file is
    /// written next to `destinationURL`.
    func exportWithComposition(
        sourceLookup: @Sendable (UUID) -> URL,
        sourceKind: @Sendable (UUID) -> MediaKind = { _ in .video },
        segments: [TimelineSegment],
        auxAudioTracks: [Track] = [],
        overlayVideoTracks: [Track] = [],
        format: ExportFormat = .mov,
        resolution: ExportResolution = .original,
        subtitleOption: SubtitleExportOption = .none,
        composedSubtitles: [ComposedSubtitle] = [],
        chapters: [VideoChapter] = [],
        chapterBarStyle: ChapterBarStyle = .default,
        voiceEnhancer: VoiceEnhancer.Settings = .disabled,
        primaryHidden: Bool = false,
        destinationURL: URL,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        guard !segments.isEmpty else { throw ExportError.noRanges }

        onProgress(ExportProgress(fractionComplete: 0.05, detail: "Loading source videos…"))

        onProgress(ExportProgress(fractionComplete: 0.1, detail: "Building composition…"))

        let burnIn: SubtitleBurnIn?
        if case .burnIn(let style) = subtitleOption, !composedSubtitles.isEmpty {
            burnIn = SubtitleBurnIn(cues: composedSubtitles, style: style)
        } else {
            burnIn = nil
        }

        let chapterBurnIn: ChapterBarBurnIn?
        if !chapters.isEmpty {
            // Prefer the last chapter's end as total duration so it
            // exactly matches the chapter list. Falls back to the sum of
            // segment durations if chapters are missing.
            let totalFromChapters = chapters.last?.endSeconds ?? 0
            let totalFromSegments = segments.reduce(0.0) { $0 + max(0, $1.durationSeconds) }
            let total = totalFromChapters > 0 ? totalFromChapters : totalFromSegments
            chapterBurnIn = ChapterBarBurnIn(chapters: chapters, totalSeconds: total, style: chapterBarStyle)
        } else {
            chapterBurnIn = nil
        }

        let result = try await CompositionBuilder.build(
            sourceLookup: sourceLookup,
            sourceKind: sourceKind,
            segments: segments,
            auxAudioTracks: auxAudioTracks,
            overlayVideoTracks: overlayVideoTracks,
            resolution: resolution,
            subtitleBurnIn: burnIn,
            chapterBurnIn: chapterBurnIn,
            primaryHidden: primaryHidden
        )

        onProgress(ExportProgress(fractionComplete: 0.3, detail: "Starting export…"))

        // Remove existing file
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        // Any non-passthrough work (effects, resolution, burn-in) forces re-encoding.
        let hasEffects = segments.contains { !$0.effects.isDefault }
            || resolution != .original
            || burnIn != nil
            || chapterBurnIn != nil
        let presetName = hasEffects ? format.presetName : format.presetName

        guard let exportSession = AVAssetExportSession(
            asset: result.composition,
            presetName: presetName
        ) else {
            guard let fallback = AVAssetExportSession(
                asset: result.composition,
                presetName: format.fallbackPresetName
            ) else {
                throw ExportError.exportFailed("No compatible export preset")
            }
            fallback.videoComposition = result.videoComposition
            fallback.audioMix = result.audioMix
            try await runExportSession(fallback, destinationURL: destinationURL, fileType: format.fileType, onProgress: onProgress)
            try writeSidecarIfNeeded(option: subtitleOption, cues: composedSubtitles, videoURL: destinationURL)
            if voiceEnhancer.enabled {
                onProgress(ExportProgress(fractionComplete: 0.95, detail: "Enhancing voice…"))
                try await applyVoiceEnhancerPostPass(
                    videoURL: destinationURL,
                    fileType: format.fileType,
                    settings: voiceEnhancer
                )
            }
            return
        }

        exportSession.videoComposition = result.videoComposition
        exportSession.audioMix = result.audioMix

        let supportedTypes = exportSession.supportedFileTypes
        let fileType = supportedTypes.contains(format.fileType) ? format.fileType : .mov

        try await runExportSession(exportSession, destinationURL: destinationURL, fileType: fileType, onProgress: onProgress)
        try writeSidecarIfNeeded(option: subtitleOption, cues: composedSubtitles, videoURL: destinationURL)
        if voiceEnhancer.enabled {
            onProgress(ExportProgress(fractionComplete: 0.95, detail: "Enhancing voice…"))
            try await applyVoiceEnhancerPostPass(
                videoURL: destinationURL,
                fileType: fileType,
                settings: voiceEnhancer
            )
        }
    }

    /// After the main export completes, extract its audio, run it
    /// through VoiceEnhancer, and remux the enhanced audio back into
    /// the video file. All work happens in the system temp directory
    /// and only touches `videoURL` at the final atomic replace.
    private func applyVoiceEnhancerPostPass(
        videoURL: URL,
        fileType: AVFileType,
        settings: VoiceEnhancer.Settings
    ) async throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cutti-voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let sourceAsset = AVURLAsset(url: videoURL)
        let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else { return } // nothing to enhance

        // 1. Dump the audio to a raw CAF file (no re-encode yet).
        let rawAudioURL = tmpRoot.appendingPathComponent("raw.caf")
        let audioOnly = AVMutableComposition()
        guard let audioCompTrack = audioOnly.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.exportFailed("VoiceEnhancer: could not allocate audio track")
        }
        let fullRange = CMTimeRange(start: .zero, duration: try await sourceAsset.load(.duration))
        try audioCompTrack.insertTimeRange(fullRange, of: audioTrack, at: .zero)

        guard let audioExport = AVAssetExportSession(
            asset: audioOnly,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExportError.exportFailed("VoiceEnhancer: no AppleM4A preset")
        }
        let audioStage = tmpRoot.appendingPathComponent("stage.m4a")
        audioExport.outputURL = audioStage
        audioExport.outputFileType = .m4a
        try await runExportSession(audioExport, destinationURL: audioStage, fileType: .m4a, onProgress: { _ in })

        // 2. Run the staged audio through VoiceEnhancer.
        let enhancedURL = tmpRoot.appendingPathComponent("enhanced.caf")
        try VoiceEnhancer.process(
            sourceURL: audioStage,
            destinationURL: enhancedURL,
            settings: settings
        )

        // 3. Remux: combine original video + enhanced audio.
        let remuxed = AVMutableComposition()
        let videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        if let vt = videoTracks.first,
           let remuxVideo = remuxed.addMutableTrack(
               withMediaType: .video,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try remuxVideo.insertTimeRange(fullRange, of: vt, at: .zero)
            remuxVideo.preferredTransform = try await vt.load(.preferredTransform)
        }
        let enhancedAsset = AVURLAsset(url: enhancedURL)
        let enhancedTracks = try await enhancedAsset.loadTracks(withMediaType: .audio)
        if let ea = enhancedTracks.first,
           let remuxAudio = remuxed.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let enhancedDuration = try await enhancedAsset.load(.duration)
            let insertRange = CMTimeRange(
                start: .zero,
                duration: CMTimeMinimum(enhancedDuration, fullRange.duration)
            )
            try remuxAudio.insertTimeRange(insertRange, of: ea, at: .zero)
        }

        let finalOut = tmpRoot.appendingPathComponent("final.\(videoURL.pathExtension)")
        guard let finalExport = AVAssetExportSession(
            asset: remuxed,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ExportError.exportFailed("VoiceEnhancer: remux preset unavailable")
        }
        finalExport.outputURL = finalOut
        finalExport.outputFileType = fileType
        try await runExportSession(finalExport, destinationURL: finalOut, fileType: fileType, onProgress: { _ in })

        // 4. Atomic replace the original export.
        _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: finalOut)
    }

    /// Emit a sibling `.srt` / `.vtt` file if the option requests it.
    private func writeSidecarIfNeeded(
        option: SubtitleExportOption,
        cues: [ComposedSubtitle],
        videoURL: URL
    ) throws {
        guard let ext = option.sidecarExtension, !cues.isEmpty else { return }
        let body: String
        switch option {
        case .sidecarSRT: body = SubtitleExporter.srt(from: cues)
        case .sidecarVTT: body = SubtitleExporter.vtt(from: cues)
        case .none, .burnIn: return
        }
        let sidecarURL = videoURL.deletingPathExtension().appendingPathExtension(ext)
        try body.write(to: sidecarURL, atomically: true, encoding: .utf8)
    }

    private func runExportSession(
        _ session: AVAssetExportSession,
        destinationURL: URL,
        fileType: AVFileType = .mov,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        session.outputURL = destinationURL
        session.outputFileType = fileType

        let startedAt = Date()
        nonisolated(unsafe) let unsafeSession = session

        // Poll progress while encoding. The first reliable sample (>=2%
        // complete, >=1s elapsed) is what Self.estimateRemainingSeconds
        // needs before it will publish an ETA so the UI doesn't jitter.
        let progressTask = Task { @Sendable in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                let p = unsafeSession.progress
                let elapsed = Date().timeIntervalSince(startedAt)
                // The export pipeline reserves 0–40% of our progress bar
                // for asset/composition prep; encoding maps to 40–95%.
                let progress = 0.4 + Double(p) * 0.55
                let eta = Self.estimateRemainingSeconds(
                    fraction: Double(p),
                    elapsedSeconds: elapsed
                )
                onProgress(ExportProgress(
                    fractionComplete: progress,
                    detail: "Encoding \(Int(p * 100))%",
                    elapsedSeconds: elapsed,
                    estimatedSecondsRemaining: eta
                ))
            }
        }

        // Swift Concurrency doesn't propagate cancellation into
        // AVAssetExportSession — it's an Objective-C completion-handler
        // API bridged as async. We MUST hook the cancellation handler
        // in the same async context as the `await session.export()`
        // call; wrapping it in a separate unstructured Task { … } (as
        // the previous implementation did) was a no-op because
        // unstructured tasks don't inherit cancellation.
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            unsafeSession.cancelExport()
        }

        progressTask.cancel()

        // If our parent Task was cancelled while export() was running,
        // session.status may report .cancelled *or* .completed depending
        // on timing. Honor the parent-cancellation signal either way so
        // the caller reliably sees CancellationError and we clean up
        // the partial file in both branches.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destinationURL)
            throw CancellationError()
        }

        switch session.status {
        case .completed:
            onProgress(ExportProgress(
                fractionComplete: 1.0,
                detail: "Export complete",
                elapsedSeconds: Date().timeIntervalSince(startedAt),
                estimatedSecondsRemaining: 0
            ))
        case .failed:
            try? FileManager.default.removeItem(at: destinationURL)
            let msg = session.error?.localizedDescription ?? "Unknown error"
            throw ExportError.exportFailed(msg)
        case .cancelled:
            try? FileManager.default.removeItem(at: destinationURL)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: destinationURL)
            throw ExportError.exportFailed("Unexpected status: \(session.status.rawValue)")
        }
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
