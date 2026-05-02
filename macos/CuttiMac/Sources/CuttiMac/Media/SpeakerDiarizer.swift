import Foundation
import SwiftUI
import CuttiKit

/// Light-weight speaker metadata. Kept intentionally simple for v0 — a
/// real product will eventually back this with a proper Speaker registry
/// persisted in the project, but the immediate goal is to give the UI a
/// stable identity per speaker so colors & names survive re-runs.
struct Speaker: Identifiable, Equatable {
    /// Zero-based stable index referenced by `SubtitleEntry.speakerID` and
    /// `ComposedSubtitle.speakerID`.
    let id: Int
    var displayName: String
    /// SwiftUI Color preset assigned at registration time.
    var color: Color
    /// Point size for the on-video speaker badge. `nil` means use the
    /// renderer's default.
    var labelSize: Double? = nil

    /// Default palette cycled through when new speakers are introduced
    /// by auto-detection. Intentionally readable on a dark video frame.
    static let palette: [Color] = [
        .yellow, .cyan, .pink, .green, .orange, .purple
    ]

    static func defaultName(for index: Int) -> String {
        L("Speaker %d", index + 1)
    }

    static func defaultColor(for index: Int) -> Color {
        palette[index % palette.count]
    }
}

/// Pure helpers for v0 speaker diarization. The real product will plug in
/// a proper diarization model (sherpa-onnx 3D-Speaker / pyannote ONNX);
/// until then we ship a deliberately simple "alternating-by-pause"
/// heuristic that's accurate enough to demo the data path and good
/// enough for two-person interview podcasts.
enum SpeakerDiarizer {

    /// Assign a speaker index to each composed cue based on the gap
    /// preceding it. Whenever the gap from the previous cue's end to the
    /// current cue's start exceeds `pauseThreshold`, we flip to the
    /// "other" speaker. With two speakers this models the natural
    /// turn-taking pattern in interviews; with more speakers it falls
    /// back to round-robin which the user can correct manually.
    /// - Parameters:
    ///   - cues: composed subtitles in chronological order.
    ///   - pauseThreshold: minimum silence (seconds) between cues to
    ///     trigger a speaker change. 1.5s is a reasonable interview default.
    ///   - speakerCount: how many distinct speakers to cycle through (>=1).
    /// - Returns: cues with `speakerID` populated.
    static func assignAlternatingBySilence(
        cues: [ComposedSubtitle],
        pauseThreshold: Double = 1.5,
        speakerCount: Int = 2
    ) -> [ComposedSubtitle] {
        guard !cues.isEmpty else { return [] }
        let n = max(1, speakerCount)
        var current = 0
        var lastEnd: Double = -.infinity
        var out: [ComposedSubtitle] = []
        out.reserveCapacity(cues.count)
        for cue in cues {
            let gap = cue.startSeconds - lastEnd
            if lastEnd >= 0, gap >= pauseThreshold {
                current = (current + 1) % n
            }
            var copy = cue
            copy.speakerID = current
            out.append(copy)
            lastEnd = cue.endSeconds
        }
        return out
    }

    /// Build the unique speaker registry implied by the IDs present on a
    /// list of cues. Names default to "Speaker N" and colors come from
    /// the palette. Stable order: by id ascending.
    static func registry(forCues cues: [ComposedSubtitle]) -> [Speaker] {
        let ids = Set(cues.compactMap(\.speakerID)).sorted()
        return ids.map { id in
            Speaker(
                id: id,
                displayName: Speaker.defaultName(for: id),
                color: Speaker.defaultColor(for: id)
            )
        }
    }
}
