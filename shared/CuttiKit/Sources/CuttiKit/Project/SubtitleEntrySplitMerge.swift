import Foundation

// MARK: - Split / merge helpers for `SubtitleEntry`
//
// Pure functions; safe to call from any actor. Used by the macOS
// transcript editor when the user wants to split one wrongly-aggregated
// cue into two, or merge two adjacent cues into one. Time-base
// alignment is automatic:
//
// - **Split**: when `wordTimings` are present, the time boundary is
//   taken from the timing whose UTF-16 cumulative range covers the
//   split offset (snapped to a word boundary). Without timings, the
//   boundary is interpolated proportional to the character ratio.
// - **Merge**: the right-hand cue's `wordTimings` are rebased so the
//   merged cue's timings are still entry-relative (0-based) on the
//   merged start.
//
// `runs` (rich text) and `translations` are dropped on **split** because
// reconstructing them across an arbitrary text boundary isn't safe.
// `runs` are dropped on **merge** for the same reason; `translations`
// are kept per-locale only when both halves carry that locale, then
// joined with the same boundary-aware joiner used for `text`.
//
// Note on time base: `WordTiming.startSeconds` / `.endSeconds` are
// **entry-relative starting from 0** (i.e. `0` is `relativeStart`).
// Splitting at `boundaryLocal` produces:
//   left:  relativeStart unchanged, relativeDuration = boundaryLocal,
//          timings as-is (already 0-based on left's start).
//   right: relativeStart = self.relativeStart + boundaryLocal,
//          relativeDuration = self.relativeDuration - boundaryLocal,
//          timings shifted by `-boundaryLocal` so they're 0-based on
//          right's new start.

extension SubtitleEntry {

    // MARK: Split

    /// Split this entry at a UTF-16 character offset into `text`.
    ///
    /// Returns `nil` when the offset is at a boundary (`0`, or
    /// `text.utf16.count`), so callers can treat that as "no-op".
    /// The left half **keeps the original `id`** so undo / selection
    /// references stay stable; the right half gets a fresh `id`.
    ///
    /// `runs` and `translations` are intentionally dropped — splitting
    /// an arbitrary character range can't preserve them safely. The
    /// existing in-app `updateSubtitleText` path makes the same
    /// trade-off, so this matches user expectations.
    public func split(atUTF16Offset offset: Int) -> (left: SubtitleEntry, right: SubtitleEntry)? {
        let nsText = text as NSString
        let total = nsText.length
        guard offset > 0, offset < total else { return nil }

        let leftText = nsText.substring(to: offset)
        let rightText = nsText.substring(from: offset)

        let boundaryLocal = Self.boundaryLocal(
            forUTF16Offset: offset,
            totalUTF16: total,
            relativeDuration: relativeDuration,
            wordTimings: wordTimings
        )

        // Tiny epsilon so we don't produce a zero-duration half (which
        // `rebuildComposedSubtitles` would silently filter out — making
        // the split look like a delete to the UI).
        let epsilon = 0.001
        let safeBoundary = min(max(boundaryLocal, epsilon), max(epsilon, relativeDuration - epsilon))

        let (leftTimings, rightTimings) = Self.partitionTimings(
            wordTimings,
            atLocalBoundary: safeBoundary
        )

        // Per-cue style override propagates to **both halves** —
        // splitting one visually-customized cue should yield two
        // visually-identical halves; the user can later reset one if
        // they want to differentiate. Translations and runs are still
        // dropped (see header comment) — preserving styleOverride is
        // safe because it's whole-cue formatting, independent of the
        // text-range invariants that make runs/translations unsafe to
        // split.
        let left = SubtitleEntry(
            id: id,
            relativeStart: relativeStart,
            relativeDuration: safeBoundary,
            text: leftText,
            speakerID: speakerID,
            translations: [:],
            runs: nil,
            wordTimings: leftTimings,
            styleOverride: styleOverride
        )
        let right = SubtitleEntry(
            id: UUID(),
            relativeStart: relativeStart + safeBoundary,
            relativeDuration: relativeDuration - safeBoundary,
            text: rightText,
            speakerID: speakerID,
            translations: [:],
            runs: nil,
            wordTimings: rightTimings,
            styleOverride: styleOverride
        )
        return (left, right)
    }

    /// Resolve the local (entry-relative, 0-based) time boundary for a
    /// UTF-16 split offset. With `wordTimings`, walks the cumulative
    /// UTF-16 length of each timing's `text` until the offset is
    /// reached and returns that timing's `startSeconds`. Falls back to
    /// proportional interpolation when timings are absent.
    private static func boundaryLocal(
        forUTF16Offset offset: Int,
        totalUTF16: Int,
        relativeDuration: Double,
        wordTimings: [WordTiming]?
    ) -> Double {
        if let timings = wordTimings, !timings.isEmpty {
            var cursor = 0
            for timing in timings {
                let timingLen = (timing.text as NSString).length
                let nextCursor = cursor + timingLen
                // Strict `<`: when offset == nextCursor the split sits
                // exactly between this timing and the next one, so the
                // boundary should be the *next* timing's start (or the
                // proportional fallback when this is the last timing).
                if offset < nextCursor {
                    return timing.startSeconds
                }
                cursor = nextCursor
            }
            // Offset past all known timings — fall through to
            // proportional. (Shouldn't happen if cumulative lengths
            // span text, but the cue's text may have been edited.)
        }
        guard totalUTF16 > 0 else { return 0 }
        return relativeDuration * Double(offset) / Double(totalUTF16)
    }

    /// Partition a `wordTimings` array at `boundaryLocal` (entry-relative
    /// seconds). Returns `(left, right)` where the right side is rebased
    /// so its timings are 0-based on the right half's new start.
    private static func partitionTimings(
        _ timings: [WordTiming]?,
        atLocalBoundary boundary: Double
    ) -> (left: [WordTiming]?, right: [WordTiming]?) {
        guard let timings, !timings.isEmpty else { return (nil, nil) }
        var leftPart: [WordTiming] = []
        var rightPart: [WordTiming] = []
        for t in timings {
            if t.startSeconds < boundary {
                // Clamp end so a timing that straddles the boundary
                // doesn't outlive the left half.
                let clampedEnd = min(t.endSeconds, boundary)
                leftPart.append(WordTiming(
                    text: t.text,
                    startSeconds: t.startSeconds,
                    endSeconds: clampedEnd
                ))
            } else {
                rightPart.append(WordTiming(
                    text: t.text,
                    startSeconds: max(0, t.startSeconds - boundary),
                    endSeconds: max(0, t.endSeconds - boundary)
                ))
            }
        }
        return (leftPart.isEmpty ? nil : leftPart,
                rightPart.isEmpty ? nil : rightPart)
    }

    // MARK: Merge

    /// Concatenate `other` after `self`. Caller must ensure `other`
    /// follows `self` in the same `TimelineSegment.subtitles[]`
    /// (adjacent indices) — the function does not check; it just
    /// folds the data.
    ///
    /// The merged cue keeps `self.id`, `self.speakerID`. Time span
    /// covers both cues' extents (so any inter-cue gap becomes silent
    /// time inside the merged cue). `runs` are dropped. Translations
    /// are kept per-locale only when both sides carry that locale.
    /// `wordTimings` are concatenated, with the right side's timings
    /// rebased so they remain 0-based on the merged cue's start (which
    /// equals `self`'s start).
    public func appending(_ other: SubtitleEntry) -> SubtitleEntry {
        let joiner = Self.naturalJoiner(left: self.text, right: other.text)
        let mergedText = self.text + joiner + other.text

        let mergedStart = self.relativeStart
        let leftEnd = self.relativeStart + self.relativeDuration
        let rightEnd = other.relativeStart + other.relativeDuration
        let mergedEnd = max(leftEnd, rightEnd)
        let mergedDuration = mergedEnd - mergedStart

        // Right wordTimings are entry-relative (0-based) on `other`,
        // so to put them on the merged frame (0-based on `self.relativeStart`)
        // we shift by `(other.relativeStart - self.relativeStart)`.
        let rightOffset = other.relativeStart - self.relativeStart

        let leftTimings = self.wordTimings ?? []
        let rightTimings = (other.wordTimings ?? []).map { t in
            WordTiming(
                text: t.text,
                startSeconds: max(0, t.startSeconds + rightOffset),
                endSeconds: max(0, t.endSeconds + rightOffset)
            )
        }

        // Sort + clamp + drop invalid. Sort tolerates the rare case
        // where leftEnd > other.relativeStart (sub-frame overlap) and
        // produces a stable order.
        let combined: [WordTiming]?
        let merged = leftTimings + rightTimings
        if merged.isEmpty {
            combined = nil
        } else {
            combined = merged
                .map { t -> WordTiming in
                    let s = min(max(0, t.startSeconds), mergedDuration)
                    let e = min(max(s, t.endSeconds), mergedDuration)
                    return WordTiming(text: t.text, startSeconds: s, endSeconds: e)
                }
                .filter { $0.endSeconds > $0.startSeconds }
                .sorted { $0.startSeconds < $1.startSeconds }
        }

        // Translations: keep only locales present in both, joined with
        // the same boundary-aware joiner. Asymmetric locales would lead
        // to a translated line whose duration covers half the cue but
        // whose text covers the whole cue — not what users expect.
        var mergedTranslations: [String: String] = [:]
        for (locale, leftValue) in self.translations {
            if let rightValue = other.translations[locale] {
                let tJoiner = Self.naturalJoiner(left: leftValue, right: rightValue)
                mergedTranslations[locale] = leftValue + tJoiner + rightValue
            }
        }

        // Per-cue style override merge policy: keep **left**'s
        // override silently. If right carries a different override,
        // it is dropped — the merged cue inherits the left's visual
        // identity, matching how `id` and `speakerID` already favor
        // the left side. V2 may surface a prompt-on-conflict instead.
        return SubtitleEntry(
            id: self.id,
            relativeStart: mergedStart,
            relativeDuration: max(0, mergedDuration),
            text: mergedText,
            speakerID: self.speakerID,
            translations: mergedTranslations,
            runs: nil,
            wordTimings: combined,
            styleOverride: self.styleOverride
        )
    }

    // MARK: Joiner

    /// Decide what string to insert between two cue texts when merging.
    /// Returns:
    /// - `""` when `left` ends with whitespace, `right` starts with
    ///   whitespace, either side is empty, OR the boundary characters
    ///   are both CJK ideographs (no inter-character space in CJK).
    /// - `" "` otherwise (Latin-style).
    static func naturalJoiner(left: String, right: String) -> String {
        guard let lastL = left.last, let firstR = right.first else { return "" }
        if lastL.isWhitespace || firstR.isWhitespace { return "" }
        if let lastScalar = left.unicodeScalars.last,
           let firstScalar = right.unicodeScalars.first,
           isCJKIdeograph(lastScalar), isCJKIdeograph(firstScalar) {
            return ""
        }
        return " "
    }

    private static func isCJKIdeograph(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x4E00...0x9FFF).contains(v)          // CJK Unified
            || (0x3400...0x4DBF).contains(v)          // Extension A
            || (0x20000...0x2A6DF).contains(v)        // Extension B
            || (0xF900...0xFAFF).contains(v)          // Compatibility
    }
}
