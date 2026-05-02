import Foundation
import CuttiKit

/// Converts the composed timeline's subtitle cues into sidecar text formats
/// (SRT, WebVTT). Pure functions — no I/O — so they are easy to test.
enum SubtitleExporter {

    /// Encode cues as SRT.
    ///
    /// Cues with empty text are skipped. Overlapping or zero-length cues are
    /// emitted as-is; consumers are responsible for cleaning composed input.
    static func srt(from cues: [ComposedSubtitle]) -> String {
        var out: [String] = []
        var index = 1
        for cue in cues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append("\(index)")
            out.append("\(srtTimestamp(cue.startSeconds)) --> \(srtTimestamp(cue.endSeconds))")
            out.append(text)
            out.append("")
            index += 1
        }
        return out.joined(separator: "\n")
    }

    /// Encode cues as WebVTT.
    static func vtt(from cues: [ComposedSubtitle]) -> String {
        var out: [String] = ["WEBVTT", ""]
        var index = 1
        for cue in cues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append("\(index)")
            out.append("\(vttTimestamp(cue.startSeconds)) --> \(vttTimestamp(cue.endSeconds))")
            out.append(text)
            out.append("")
            index += 1
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Timestamps

    /// Format as `HH:MM:SS,mmm` (SRT).
    static func srtTimestamp(_ seconds: Double) -> String {
        let (h, m, s, ms) = splitTime(seconds)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// Format as `HH:MM:SS.mmm` (VTT).
    static func vttTimestamp(_ seconds: Double) -> String {
        let (h, m, s, ms) = splitTime(seconds)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private static func splitTime(_ seconds: Double) -> (Int, Int, Int, Int) {
        let clamped = max(0, seconds)
        // Round to nearest millisecond to avoid floor(0.9999999) issues.
        let totalMs = Int((clamped * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1_000
        let ms = totalMs % 1_000
        return (h, m, s, ms)
    }
}
