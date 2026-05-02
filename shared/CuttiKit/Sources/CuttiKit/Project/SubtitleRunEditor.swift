import Foundation

/// Pure functions for manipulating `[SubtitleRun]` arrays. Safe to call
/// from any actor; no state, no I/O. All operations operate on **UTF-16
/// character offsets** in the concatenated plain text — the same unit
/// Core Text (`CTFramesetter` / `NSAttributedString.Index`) uses, so hit-
/// test results from the preview overlay can be fed directly to
/// `applyStyle` without conversion.
///
/// Invariants maintained by this module:
/// - No empty-text run ever appears in a returned array (except the
///   degenerate case where the whole cue is empty, which yields `[]`).
/// - Adjacent runs never share the same style — `normalize` always runs
///   at the end of mutating operations.
/// - `plainText(before) == plainText(after)` for every operation that
///   only changes styling (split, applyStyle, normalize).
public enum SubtitleRunEditor {

    // MARK: - Construction helpers

    /// Wrap a plain string in a single unstyled run. Used when migrating
    /// legacy cues (`SubtitleEntry.runs == nil`) into the rich-text world
    /// on first edit.
    public static func singleRun(_ text: String) -> [SubtitleRun] {
        guard !text.isEmpty else { return [] }
        return [SubtitleRun(text: text, style: .empty)]
    }

    /// Concatenated plain text of all runs, in order.
    public static func plainText(_ runs: [SubtitleRun]) -> String {
        runs.map(\.text).joined()
    }

    /// Total UTF-16 length of the concatenated plain text. Matches the
    /// unit used by `range:` arguments throughout this module.
    public static func utf16Length(_ runs: [SubtitleRun]) -> Int {
        runs.reduce(0) { $0 + $1.text.utf16.count }
    }

    // MARK: - Split

    /// Split runs so that every offset in `offsets` falls on a run
    /// boundary. Runs are split in place (the left half keeps the
    /// original id; the right half gets a new id). Offsets that already
    /// fall on a boundary, or lie outside `[0, totalLength]`, are
    /// silently skipped.
    ///
    /// The returned array's concatenated text is identical to the input.
    public static func split(runs: [SubtitleRun], at offsets: [Int]) -> [SubtitleRun] {
        guard !runs.isEmpty, !offsets.isEmpty else { return runs }
        let total = utf16Length(runs)
        // Dedup + filter + sort. Boundaries at 0 and `total` are no-ops.
        let sorted = Array(Set(offsets)).filter { $0 > 0 && $0 < total }.sorted()
        guard !sorted.isEmpty else { return runs }

        var result: [SubtitleRun] = []
        result.reserveCapacity(runs.count + sorted.count)
        var cursor = 0
        var pending = sorted[...]

        for run in runs {
            let runLen = run.text.utf16.count
            let runStart = cursor
            let runEnd = cursor + runLen

            // Pull every offset that falls strictly inside this run.
            var localCuts: [Int] = []
            while let next = pending.first, next < runEnd {
                if next > runStart {
                    localCuts.append(next - runStart)
                }
                pending = pending.dropFirst()
            }

            if localCuts.isEmpty {
                result.append(run)
            } else {
                var remaining = run.text
                var emittedFirst = false
                var lastCut = 0
                for cut in localCuts {
                    let piece = substring(remaining, upToUtf16: cut - lastCut)
                    remaining = substring(remaining, fromUtf16: cut - lastCut)
                    let id = emittedFirst ? UUID() : run.id
                    result.append(SubtitleRun(id: id, text: piece, style: run.style))
                    emittedFirst = true
                    lastCut = cut
                }
                if !remaining.isEmpty {
                    result.append(
                        SubtitleRun(id: UUID(), text: remaining, style: run.style))
                }
            }

            cursor = runEnd
        }

        return result
    }

    // MARK: - Apply style

    /// Merge `patch` into the style of every run that overlaps
    /// `[range.lowerBound, range.upperBound)` (UTF-16 offsets into the
    /// concatenated plain text). Splits runs at the range boundaries,
    /// merges the patch onto the covered runs (nil fields in `patch`
    /// leave the run's corresponding field alone), then normalizes
    /// adjacent equal-style runs.
    ///
    /// Empty or out-of-bounds ranges are no-ops.
    public static func applyStyle(
        to runs: [SubtitleRun],
        range: Range<Int>,
        patch: SubtitleRunStyle
    ) -> [SubtitleRun] {
        let total = utf16Length(runs)
        let lo = max(0, range.lowerBound)
        let hi = min(total, range.upperBound)
        guard lo < hi else { return runs }

        let boundaried = split(runs: runs, at: [lo, hi])

        var updated: [SubtitleRun] = []
        updated.reserveCapacity(boundaried.count)
        var cursor = 0
        for run in boundaried {
            let runLen = run.text.utf16.count
            let runStart = cursor
            let runEnd = cursor + runLen
            if runStart >= lo && runEnd <= hi {
                var copy = run
                copy.style = run.style.merging(patch)
                updated.append(copy)
            } else {
                updated.append(run)
            }
            cursor = runEnd
        }

        return normalize(updated)
    }

    /// Replace (not merge) the style of every run inside `range` with
    /// `style`. Use this when the caller wants to explicitly clear
    /// overrides — passing `.empty` here resets the range to plain cue
    /// styling, which `applyStyle(..., patch:)` cannot do because its
    /// nil-is-leave semantics prevent clearing.
    public static func setStyle(
        on runs: [SubtitleRun],
        range: Range<Int>,
        style: SubtitleRunStyle
    ) -> [SubtitleRun] {
        let total = utf16Length(runs)
        let lo = max(0, range.lowerBound)
        let hi = min(total, range.upperBound)
        guard lo < hi else { return runs }

        let boundaried = split(runs: runs, at: [lo, hi])
        var updated: [SubtitleRun] = []
        updated.reserveCapacity(boundaried.count)
        var cursor = 0
        for run in boundaried {
            let runLen = run.text.utf16.count
            let runStart = cursor
            let runEnd = cursor + runLen
            if runStart >= lo && runEnd <= hi {
                var copy = run
                copy.style = style
                updated.append(copy)
            } else {
                updated.append(run)
            }
            cursor = runEnd
        }
        return normalize(updated)
    }

    // MARK: - Normalize

    /// Merge adjacent runs that share the same style. Drops empty-text
    /// runs. The left run wins on id collisions. This is called
    /// automatically by `applyStyle` / `setStyle`; callers who build
    /// runs manually (e.g. paste/insert flows) should call it too.
    public static func normalize(_ runs: [SubtitleRun]) -> [SubtitleRun] {
        var result: [SubtitleRun] = []
        result.reserveCapacity(runs.count)
        for run in runs {
            guard !run.text.isEmpty else { continue }
            if var last = result.last, last.style == run.style {
                last.text.append(run.text)
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
        return result
    }

    // MARK: - UTF-16 substring helpers

    /// Substring of `source` up to `utf16Count` code units. Returns "" if
    /// the count is out of range.
    private static func substring(_ source: String, upToUtf16 utf16Count: Int) -> String {
        guard utf16Count > 0 else { return "" }
        let utf16View = source.utf16
        let endIndex = utf16View.index(
            utf16View.startIndex,
            offsetBy: min(utf16Count, utf16View.count)
        )
        if let str = String(utf16View[utf16View.startIndex..<endIndex]) {
            return str
        }
        // Fallback: scalar-safe slice when utf16 boundary falls inside a
        // surrogate pair. We conservatively keep the whole scalar.
        return String(source.prefix(utf16Count))
    }

    private static func substring(_ source: String, fromUtf16 utf16Offset: Int) -> String {
        guard utf16Offset > 0 else { return source }
        let utf16View = source.utf16
        let startIndex = utf16View.index(
            utf16View.startIndex,
            offsetBy: min(utf16Offset, utf16View.count)
        )
        if let str = String(utf16View[startIndex..<utf16View.endIndex]) {
            return str
        }
        return String(source.dropFirst(utf16Offset))
    }
}
