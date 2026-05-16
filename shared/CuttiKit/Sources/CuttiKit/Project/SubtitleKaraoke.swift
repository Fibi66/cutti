import Foundation

// MARK: - WordTiming

/// A single word timestamp. Times are stored **relative to the parent
/// `SubtitleEntry.relativeStart`** (i.e. entry-local), not absolute
/// composed-timeline seconds. This keeps the data stable across timeline
/// edits (trims / deletes / reorders) — only `ComposedSubtitle`
/// re-keys into composed-timeline absolute time at compose time.
///
/// The `text` slice carries the exact UTF-16 substring the timing
/// refers to (as emitted by the active ASR backend — Qwen3-ASR or
/// Apple Speech). Karaoke rendering uses the cumulative position of
/// these slices to locate the word's UTF-16 range in the cue's plain
/// text — no fuzzy matching, because the slices are guaranteed by
/// construction to concatenate to the cue text (minus trimmed leading
/// whitespace inserted by the ASR, which the composer tolerates).
public struct WordTiming: Codable, Equatable, Hashable, Sendable {
    /// The word / token text as emitted by the transcriber. May carry
    /// leading whitespace (e.g. " hello") — the composer handles both.
    public let text: String
    /// Entry-relative start time in seconds.
    public let startSeconds: Double
    /// Entry-relative end time in seconds. Must be >= `startSeconds`.
    public let endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = max(startSeconds, endSeconds)
    }
}

// MARK: - SubtitleKaraokeOptions

/// Karaoke-mode configuration at the cue-style level. Opt-in: when
/// `enabled == false` (the default) the renderer behaves identically
/// to pre-karaoke builds — zero rendering cost, no visual change.
///
/// When enabled, the renderer looks up each cue's `wordTimings` and
/// asks `SubtitleKaraokeComposer` to produce a single "overlay run"
/// that tags the currently-spoken word with `highlight`, composed on
/// top of any user-authored `SubtitleRun` emphasis. The two do not
/// conflict — karaoke is a dynamic, time-varying run; user emphasis
/// is a static one. Merge semantics apply per field (`highlight`
/// fields on the karaoke style stomp, others inherit).
public struct SubtitleKaraokeOptions: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    /// Style applied to the currently-spoken word. Typical values:
    /// a bright `highlightBackground`, a larger `sizeMultiplier`, or
    /// both. Defaults to a yellow pill at 1.0x size (no scale change)
    /// so the motion comes from the pill sweep rather than jitter.
    public var highlight: SubtitleRunStyle

    public init(enabled: Bool, highlight: SubtitleRunStyle) {
        self.enabled = enabled
        self.highlight = highlight
    }

    public static let disabled = SubtitleKaraokeOptions(
        enabled: false,
        highlight: .empty
    )

    /// Yellow pill, no size change. Reads on dark backgrounds and
    /// avoids the "bouncing word" visual that cheap karaoke plugins
    /// make look amateurish.
    public static let defaultYellowPill = SubtitleKaraokeOptions(
        enabled: true,
        highlight: SubtitleRunStyle(
            highlightBackground: SubtitleStyle.RGBAColor(
                red: 1.0, green: 0.84, blue: 0.0, alpha: 0.85
            )
        )
    )
}

// MARK: - SubtitleKaraokeComposer

/// Pure resolver: given a cue's word timings and a playhead time,
/// return the UTF-16 range of the currently-spoken word in the cue's
/// plain text, plus the karaoke overlay run set that can be merged
/// into the existing runs before rendering.
///
/// The composer is intentionally stateless and Foundation-only so
/// both iOS and macOS renderers can call it and so unit tests don't
/// need a host view model.
public struct SubtitleKaraokeComposer {

    /// Find the word active at `entryRelativeTime` (seconds from the
    /// cue's start). Returns the UTF-16 range of that word inside
    /// `cueText`, or nil when:
    ///   - `wordTimings` is nil or empty
    ///   - no timing covers the time (before the first word, after
    ///     the last, or in a gap between words)
    ///
    /// The range is computed by accumulating UTF-16 lengths of each
    /// timing's `text` in order. We tolerate the ASR's habit of
    /// emitting a leading space on subsequent words (" hello") by
    /// trimming the leading whitespace from the range (the space is
    /// counted in the cursor so offsets stay aligned, but the
    /// highlighted range starts at the first non-space char).
    public static func activeWordRange(
        cueText: String,
        wordTimings: [WordTiming]?,
        entryRelativeTime: Double
    ) -> NSRange? {
        guard let wordTimings, !wordTimings.isEmpty else { return nil }

        // Binary-search-style linear scan: timings are small (a cue is
        // usually <20 words), linear is fast enough and simpler than
        // maintaining sort invariants.
        let ns = cueText as NSString
        var cursor = 0
        let textLen = ns.length

        for timing in wordTimings {
            let slice = timing.text as NSString
            let sliceLen = slice.length
            guard sliceLen > 0 else { continue }

            // Find where this slice starts in the cue text. The ASR
            // can emit leading whitespace on tokens (" hello"); the
            // concatenation should still match when we walk cursor by
            // the raw slice length. If the cursor-relative slice
            // doesn't match the cue text (drift), fall back to a
            // search starting at cursor so we don't crash on odd data.
            var matchLoc = cursor
            if cursor + sliceLen <= textLen,
               ns.substring(with: NSRange(location: cursor, length: sliceLen))
                == timing.text
            {
                matchLoc = cursor
            } else {
                let searchRange = NSRange(
                    location: cursor,
                    length: textLen - cursor
                )
                let hit = ns.range(
                    of: timing.text,
                    options: [.literal],
                    range: searchRange
                )
                if hit.location == NSNotFound {
                    // Drift — skip this timing without advancing.
                    continue
                }
                matchLoc = hit.location
            }

            // Check if the playhead is inside this word.
            if entryRelativeTime >= timing.startSeconds
                && entryRelativeTime < timing.endSeconds {
                // Trim leading whitespace so the pill hugs the word.
                var trimStart = matchLoc
                var trimLen = sliceLen
                while trimLen > 0 {
                    let ch = ns.character(at: trimStart)
                    // ASCII space or common CJK full-width space (0x3000)
                    guard ch == 0x20 || ch == 0x3000 || ch == 0x09 else { break }
                    trimStart += 1
                    trimLen -= 1
                }
                guard trimLen > 0 else { return nil }
                return NSRange(location: trimStart, length: trimLen)
            }

            cursor = matchLoc + sliceLen
        }

        return nil
    }

    /// Build a fresh `[SubtitleRun]` that carries the user's
    /// authored runs (if any) with `highlightStyle` merged onto the
    /// active word's range. When no word is active (pre/post cue, in
    /// a gap), returns the input runs (or a nil-equivalent) unchanged.
    ///
    /// Parameters:
    ///   - cueText: plain-text cue.
    ///   - baseRuns: user-authored runs, or nil for plain cues.
    ///   - wordTimings: entry-relative word timestamps.
    ///   - entryRelativeTime: playhead seconds from cue start.
    ///   - highlightStyle: the per-run patch applied to the active
    ///     word (typically the karaoke style's `highlight`).
    ///
    /// The returned runs always satisfy the invariant
    /// `SubtitleRunEditor.plainText(out) == cueText`, so the existing
    /// renderers can feed them straight into `makeAttributedString`.
    public static func composedRuns(
        cueText: String,
        baseRuns: [SubtitleRun]?,
        wordTimings: [WordTiming]?,
        entryRelativeTime: Double,
        highlightStyle: SubtitleRunStyle
    ) -> [SubtitleRun]? {
        guard let activeRange = activeWordRange(
            cueText: cueText,
            wordTimings: wordTimings,
            entryRelativeTime: entryRelativeTime
        ) else {
            return baseRuns
        }

        // Seed a single run from the plain cue text when the caller
        // didn't author any — this lets us apply the karaoke overlay
        // without the renderer needing a separate "no base" path.
        let seeded: [SubtitleRun] = baseRuns
            ?? [SubtitleRun(text: cueText, style: .empty)]

        let utf16Range = (activeRange.location)..<(activeRange.location + activeRange.length)
        let merged = SubtitleRunEditor.applyStyle(
            to: seeded,
            range: utf16Range,
            patch: highlightStyle
        )
        let normalized = SubtitleRunEditor.normalize(merged)
        return normalized
    }
}
