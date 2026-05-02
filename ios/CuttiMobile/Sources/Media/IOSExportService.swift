import Foundation
import AVFoundation
import Photos
import CuttiKit

/// Exports the primary-track composition to an MP4 file and saves it
/// into the Photos library. Mirrors the minimum of what macOS's
/// `AIVideoExporter` does — no overlays / transitions / color filters
/// yet (those live on macOS's full renderer); iOS export respects
/// segment ranges + per-segment volume + speed and segment order.
///
/// The full macOS renderer can be ported later; for now this service
/// is sufficient for "edit on phone, share the result".
@MainActor
enum IOSExportService {

    struct Progress {
        var fraction: Float
        var stage: Stage
    }

    /// Caller-owned handle that lets the UI cancel an in-flight export.
    /// The handle is passed into `export` which populates `session`
    /// just before awaiting — callers hold the handle and call
    /// `cancel()` to interrupt.
    @MainActor
    final class Handle {
        fileprivate var session: AVAssetExportSession?
        fileprivate(set) var isCancelled: Bool = false

        func cancel() {
            isCancelled = true
            session?.cancelExport()
        }
    }

    enum Stage {
        case preparing
        case rendering
        case saving
        case done(URL)
        case failed(String)
    }

    enum Preset {
        case p720
        case p1080
        case p4k

        var avPreset: String {
            switch self {
            case .p720:  return AVAssetExportPreset1280x720
            case .p1080: return AVAssetExportPreset1920x1080
            case .p4k:   return AVAssetExportPreset3840x2160
            }
        }
        var label: String {
            switch self {
            case .p720:  return "720P"
            case .p1080: return "1080P"
            case .p4k:   return "4K"
            }
        }
    }

    enum ExportError: LocalizedError {
        case noPlayable
        case sessionCreateFailed
        case exportFailed(String?)
        case photosDenied
        case photosSaveFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPlayable:          return "没有可导出的片段。"
            case .sessionCreateFailed: return "无法创建导出会话。"
            case .exportFailed(let m): return "导出失败：\(m ?? "未知错误")"
            case .photosDenied:        return "请允许访问照片才能保存导出。"
            case .photosSaveFailed(let m): return "保存到相册失败：\(m)"
            }
        }
    }

    /// Kick off an export. Progress updates are delivered via `onProgress`
    /// on the main actor. Completes when the file is saved into Photos
    /// (or an error is reported).
    static func export(
        tracks: [Track],
        manifest: MediaManifest,
        projectRoot: URL,
        preset: Preset,
        aspectRatio: ProjectDocument.AspectRatio = .portrait9x16,
        background: ProjectDocument.BackgroundStyle = .color(.init(red: 0, green: 0, blue: 0, alpha: 1)),
        visualEffects: [UUID: ProjectDocument.VisualEffectPreset] = [:],
        textOverlays: [IOSSessionState.TextOverlay] = [],
        transitions: [UUID: Double] = [:],
        chapters: [VideoChapter] = [],
        chapterStyle: ChapterBarStyle = .default,
        handle: Handle? = nil,
        onProgress: @escaping (Progress) -> Void
    ) async {
        onProgress(Progress(fraction: 0, stage: .preparing))

        guard let primary = tracks.first(where: { $0.kind == .video }),
              !primary.segments.isEmpty else {
            onProgress(Progress(fraction: 0, stage: .failed(ExportError.noPlayable.localizedDescription ?? "")))
            return
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            onProgress(Progress(fraction: 0, stage: .failed(ExportError.sessionCreateFailed.localizedDescription ?? "")))
            return
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        // Auxiliary audio track from `.audio`-kind tracks (imported
        // music). Mixed together with the primary audio by AVFoundation.
        let musicTrack: AVMutableCompositionTrack? = {
            guard tracks.contains(where: { $0.kind == .audio && !$0.segments.isEmpty }) else { return nil }
            return composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }()

        let mediaByID = Dictionary(uniqueKeysWithValues: manifest.media.map { ($0.id, $0) })
        var cursor: CMTime = .zero
        var appended = 0
        let audioMixInputs: NSMutableArray = []
        var visualPlans: [IOSCompositionBuilder.SegmentVisual] = []

        for segment in primary.segments {
            guard let asset = mediaByID[segment.sourceVideoID] else { continue }
            let url = resolveURL(for: asset, projectRoot: projectRoot)
            let avAsset = AVURLAsset(url: url)
            let start = CMTime(seconds: segment.range.startSeconds, preferredTimescale: 600)
            let end = CMTime(seconds: segment.range.endSeconds, preferredTimescale: 600)
            let range = CMTimeRange(start: start, end: end)
            guard range.duration > .zero else { continue }

            let srcV = avAsset.tracks(withMediaType: .video)
            let srcA = avAsset.tracks(withMediaType: .audio)
            guard let sv = srcV.first else { continue }
            do {
                try videoTrack.insertTimeRange(range, of: sv, at: cursor)
            } catch { continue }
            if let audioTrack, let sa = srcA.first {
                try? audioTrack.insertTimeRange(range, of: sa, at: cursor)
                let inserted = CMTimeRange(start: cursor, duration: range.duration)
                if let p = IOSCompositionBuilder.audioMixParams(
                    forTrack: audioTrack,
                    baseVolume: Float(segment.volumeLevel),
                    fadeIn: segment.effects.audioFadeInDuration,
                    fadeOut: segment.effects.audioFadeOutDuration,
                    insertedRange: inserted
                ) {
                    audioMixInputs.add(p)
                }
            }
            cursor = CMTimeAdd(cursor, range.duration)
            appended += 1
            visualPlans.append(IOSCompositionBuilder.SegmentVisual(
                composedRange: CMTimeRange(
                    start: CMTimeSubtract(cursor, range.duration),
                    duration: range.duration
                ),
                effects: segment.effects,
                visualPreset: visualEffects[segment.id] ?? .none,
                fadeOutSeconds: transitions[segment.id] ?? 0
            ))
        }

        // Mirror the preview builder's pair-up pass: each segment's
        // exit-transition becomes the next segment's entry fade-in.
        // Last plan can't fade out because nothing follows. Use
        // indices.dropFirst() rather than `1..<count` so an empty
        // visualPlans array doesn't trap in Range init before the
        // `appended > 0` guard below gets a chance to bail out.
        for i in visualPlans.indices.dropFirst() {
            let prevOut = visualPlans[i - 1].fadeOutSeconds
            if prevOut > 0 {
                visualPlans[i].fadeInSeconds = prevOut
            }
        }
        for i in visualPlans.indices {
            let halfDur = visualPlans[i].composedRange.duration.seconds / 2
            visualPlans[i].fadeInSeconds = min(visualPlans[i].fadeInSeconds, halfDur)
            visualPlans[i].fadeOutSeconds = min(visualPlans[i].fadeOutSeconds, halfDur)
        }
        if !visualPlans.isEmpty {
            visualPlans[visualPlans.count - 1].fadeOutSeconds = 0
        }

        guard appended > 0 else {
            onProgress(Progress(fraction: 0, stage: .failed(ExportError.noPlayable.localizedDescription ?? "")))
            return
        }

        // Lay out music/audio-track segments on the aux track. These
        // play at their sequential cursor from 0 on the music track.
        if let musicTrack {
            var musicCursor: CMTime = .zero
            for mt in tracks where mt.kind == .audio {
                for seg in mt.segments {
                    guard let asset = mediaByID[seg.sourceVideoID] else { continue }
                    let url = resolveURL(for: asset, projectRoot: projectRoot)
                    let a = AVURLAsset(url: url)
                    guard let src = a.tracks(withMediaType: .audio).first else { continue }
                    let s = CMTime(seconds: seg.range.startSeconds, preferredTimescale: 600)
                    let e = CMTime(seconds: seg.range.endSeconds, preferredTimescale: 600)
                    let r = CMTimeRange(start: s, end: e)
                    guard r.duration > .zero else { continue }
                    try? musicTrack.insertTimeRange(r, of: src, at: musicCursor)
                    let inserted = CMTimeRange(start: musicCursor, duration: r.duration)
                    if let p = IOSCompositionBuilder.audioMixParams(
                        forTrack: musicTrack,
                        baseVolume: Float(seg.volumeLevel),
                        fadeIn: seg.effects.audioFadeInDuration,
                        fadeOut: seg.effects.audioFadeOutDuration,
                        insertedRange: inserted
                    ) {
                        audioMixInputs.add(p)
                    }
                    musicCursor = CMTimeAdd(musicCursor, r.duration)
                }
            }
        }

        // Lay out overlay-track segments (picture-in-picture). Each gets
        // its own video track so the custom compositor can address it.
        var overlayPlans: [IOSPiPOverlayPlan] = []
        for ot in tracks where ot.kind == .overlay {
            for seg in ot.segments {
                guard let asset = mediaByID[seg.sourceVideoID] else { continue }
                let url = resolveURL(for: asset, projectRoot: projectRoot)
                let a = AVURLAsset(url: url)
                guard let src = a.tracks(withMediaType: .video).first else { continue }
                let s = CMTime(seconds: seg.range.startSeconds, preferredTimescale: 600)
                let e = CMTime(seconds: seg.range.endSeconds, preferredTimescale: 600)
                let r = CMTimeRange(start: s, end: e)
                guard r.duration > .zero else { continue }
                guard let oTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                let at = CMTime(seconds: max(0, seg.placementOffset ?? 0), preferredTimescale: 600)
                do {
                    try oTrack.insertTimeRange(r, of: src, at: at)
                } catch { continue }
                overlayPlans.append(IOSPiPOverlayPlan(
                    trackID: oTrack.trackID,
                    composedRange: CMTimeRange(start: at, duration: r.duration),
                    pipLayout: seg.pipLayout,
                    freeTransform: seg.freeTransform
                ))
            }
        }

        // A custom canvas (aspect + background) requires an
        // AVAssetExportSession whose preset honours videoComposition
        // .renderSize. The dimension-named presets (e.g.
        // AVAssetExportPreset1920x1080) force their own output size
        // and letterbox ours; HighestQuality respects the
        // composition's renderSize while still producing a sensible
        // bit rate.
        let maxSide: CGFloat = {
            switch preset {
            case .p720:  return 1280
            case .p1080: return 1920
            case .p4k:   return 3840
            }
        }()
        let targetRenderSize = IOSCompositionBuilder.exportRenderSize(
            for: aspectRatio, maxLongSide: maxSide
        )
        let presetName = AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: presetName
        ) else {
            onProgress(Progress(fraction: 0, stage: .failed(ExportError.sessionCreateFailed.localizedDescription ?? "")))
            return
        }

        let outURL = FileManager.default.temporaryDirectory
            .appending(path: "cutti-export-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)

        session.outputFileType = .mp4
        session.outputURL = outURL
        session.shouldOptimizeForNetworkUse = true
        if audioMixInputs.count > 0 {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioMixInputs.compactMap { $0 as? AVAudioMixInputParameters }
            session.audioMix = mix
        }
        if !overlayPlans.isEmpty {
            // Multi-track PiP path. Build a custom videoComposition
            // that aspect-fits the primary into the target canvas,
            // fills the letterbox with the requested background, and
            // composites every PiP overlay on top in canvas space.
            let primaryTrackID = composition.tracks(withMediaType: .video).first?.trackID
            let totalDuration = max(
                cursor,
                overlayPlans.map { CMTimeAdd($0.composedRange.start, $0.composedRange.duration) }.max() ?? .zero
            )
            let chapterBurnIn: IOSCompositionBuilder.ChapterBurnIn? = chapters.isEmpty ? nil :
                .init(chapters: chapters, totalSeconds: totalDuration.seconds, style: chapterStyle)
            let vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = IOSPiPCompositor.self
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            vc.renderSize = targetRenderSize
            vc.instructions = [IOSPiPInstruction(
                timeRange: CMTimeRange(start: .zero, duration: totalDuration),
                primaryTrackID: primaryTrackID,
                primaryPlans: visualPlans,
                overlays: overlayPlans,
                textOverlays: textOverlays,
                exportCanvas: (renderSize: targetRenderSize, background: background),
                chapterBurnIn: chapterBurnIn
            )]
            session.videoComposition = vc
        } else if let vc = IOSCompositionBuilder.buildVideoComposition(
            asset: composition,
            plans: visualPlans,
            exportCanvas: (renderSize: targetRenderSize, background: background),
            textOverlays: textOverlays,
            chapterBurnIn: chapters.isEmpty ? nil : .init(
                chapters: chapters,
                totalSeconds: cursor.seconds,
                style: chapterStyle
            )
        ) {
            session.videoComposition = vc
        }

        // Hand the session to the caller's handle so ⌫/取消 can
        // interrupt a long render. If the handle was already cancelled
        // (race: user tapped cancel before we got here), bail now.
        handle?.session = session
        if handle?.isCancelled == true {
            onProgress(Progress(fraction: 0, stage: .failed("已取消")))
            return
        }

        // Progress polling: AVAssetExportSession publishes progress as
        // a plain `Float` (0...1), so spin a light timer to forward it
        // until completion.
        let pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if session.status == .completed || session.status == .failed || session.status == .cancelled {
                    break
                }
                onProgress(Progress(fraction: session.progress, stage: .rendering))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        await session.export()
        pollTask.cancel()

        switch session.status {
        case .completed:
            onProgress(Progress(fraction: 1.0, stage: .saving))
            do {
                try await saveToPhotos(fileURL: outURL)
                // Keep the file around so the Share Sheet can hand it
                // off to other apps. iOS cleans NSTemporaryDirectory()
                // on its own schedule; for an average mobile export
                // (< 500MB) that is fine.
                onProgress(Progress(fraction: 1.0, stage: .done(outURL)))
            } catch {
                onProgress(Progress(fraction: 1.0, stage: .failed(error.localizedDescription)))
                try? FileManager.default.removeItem(at: outURL)
            }
        case .failed:
            onProgress(Progress(fraction: session.progress,
                                stage: .failed(session.error?.localizedDescription ?? "未知错误")))
        case .cancelled:
            onProgress(Progress(fraction: session.progress, stage: .failed("已取消")))
        default:
            onProgress(Progress(fraction: session.progress, stage: .failed("状态异常")))
        }
    }

    private static func saveToPhotos(fileURL: URL) async throws {
        let status = await requestAddOnlyPhotosAuth()
        guard status == .authorized || status == .limited else {
            throw ExportError.photosDenied
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }, completionHandler: { ok, err in
                if ok { cont.resume() }
                else { cont.resume(throwing: ExportError.photosSaveFailed(err?.localizedDescription ?? "")) }
            })
        }
    }

    private static func requestAddOnlyPhotosAuth() async -> PHAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cont.resume(returning: status)
            }
        }
    }

    private static func resolveURL(for asset: MediaAssetRecord, projectRoot: URL) -> URL {
        if let proxyRel = asset.derived.proxyRelativePath {
            let proxyURL = projectRoot.appending(path: proxyRel)
            if FileManager.default.fileExists(atPath: proxyURL.path) {
                return proxyURL
            }
        }
        return URL(fileURLWithPath: asset.sourcePath)
    }
}
